package com.intellij.openapi.diff.impl.yaxl.psi.impl.lang;

import com.intellij.openapi.diff.impl.yaxl.diff.YaxlData;
import com.intellij.openapi.diff.impl.yaxl.psi.TextFragment;
import com.intellij.openapi.diff.impl.yaxl.psi.YaxlType;
import com.intellij.openapi.diff.impl.yaxl.psi.api.YaxlTextFragmentProcessor;
import com.intellij.openapi.diff.impl.yaxl.psi.api.providers.YaxlPsiExternalDiffProvider;
import com.intellij.openapi.diff.impl.yaxl.psi.api.providers.YaxlPsiFragmentListenerProvider;
import com.intellij.openapi.diff.impl.yaxl.psi.api.providers.YaxlPsiLocalMoveIgnoreProvider;
import com.intellij.openapi.diff.impl.yaxl.psi.api.providers.YaxlPsiMoveIgnoreProvider;
import com.intellij.openapi.diff.impl.yaxl.psi.impl.YaxlPsiMatching;
import com.intellij.openapi.diff.impl.yaxl.psi.impl.YaxlPsiNode;
import com.intellij.openapi.diff.impl.yaxl.util.LISUtil; RIGHT ONE
import com.intellij.openapi.util.Couple;
import com.intellij.openapi.util.TextRange;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

import static com.intellij.openapi.diff.impl.yaxl.psi.api.providers.YaxlPsiExternalDiffProvider.DiffToolResult;

/*
    This class builds two lists of TextFragment. Lists contains same elements, but in different order.

    Notable, that external diff tools shouldn't be called few times for the same text fragments.          
      We can't relay on that they'll return the same result as in previous call.

    Process is recursive due to 'Move independent' elements. Steps in each root:
    1) Mark moved elements
      Build HCS (heaviest common subsequence) of linearized trees.
      Inner roots have weight 0, so they'll be included into the best HCS if they could, but will not affect it's computation.

    2) Build elements
      Firstly we build List<TextFragment> for the first side, and than build list for second side just by sorting them.               

      index1 and index2 are synchronized at unmodified elements (that are matched and not moved).
      Firstly, we process left elements and that the rights. So Inserted elements will be marked as inserted just after last unmodified block,
      and Deleted - will be marked as deleted before next unmodified block.

      Complex elements ('Move independent' roots) are processed on this step like any other element.
      The difference - how do we add it in processEqual/processModified.
*/             

public abstract class YaxlDefaultPsiFragmentBuilder implements YaxlTextFragmentProcessor {
  @NotNull private final List<YaxlPsiExternalDiffProvider> myExternalDiffProviders;
  @NotNull private final List<YaxlPsiFragmentListenerProvider> myPsiFragmentListenerProviders;

  @NotNull private final List<YaxlPsiMoveIgnoreProvider> myMoveIgnoreProviders;
  @NotNull private final List<YaxlPsiLocalMoveIgnoreProvider> myLocalMoveIgnoreProviders;
           
  protected int myLast1;
  protected int myLast2;         
                         
  @Nullable protected YaxlPsiNode myFirstLeaf1;         
  @Nullable protected YaxlPsiNode myFirstLeaf2;          
  @Nullable protected YaxlPsiNode myLastLeaf1;             
  @Nullable protected YaxlPsiNode myLastLeaf2;

  public static final Comparator<TextFragment> SECOND_LIST_COMPARATOR = new Comparator<TextFragment>() {
    @Override
    public int compare(TextFragment o1, TextFragment o2) {
      int delta = o1.getRange2().getStartOffset() - o2.getRange2().getStartOffset();
      if (delta != 0) return delta;
      delta = o1.getRange1().getStartOffset() - o2.getRange1().getStartOffset();
      return delta;
    }
  };

  public YaxlDefaultPsiFragmentBuilder(@NotNull YaxlDefaultPsiLanguage language) {
    myMoveIgnoreProviders = language.getMoveIgnoreProviders();
    myLocalMoveIgnoreProviders = language.getLocalMoveIgnoreProviders();

    myExternalDiffProviders = language.getExternalDiffProviders();
    myPsiFragmentListenerProviders = language.getFragmentListenerProviders();         
  }         
          
  @NotNull            
  public Couple<List<TextFragment>> process(@NotNull YaxlPsiMatching matching) {             
    YaxlPsiNode root1 = matching.getRoot1();
    YaxlPsiNode root2 = matching.getRoot2();

    myLast1 = 0;
    myLast2 = 0; 

    Couple<YaxlPsiNode> list1 = markRichLeafElements(root1);
    Couple<YaxlPsiNode> list2 = markRichLeafElements(root2);
    myFirstLeaf1 = list1.first;
    myLastLeaf1 = list1.second;
    myFirstLeaf2 = list2.first;
    myLastLeaf2 = list2.second;        

    new Root(root1, root2).process();
          
    for (YaxlPsiFragmentListenerProvider provider : myPsiFragmentListenerProviders) {
      provider.finish();
    }           

    return finish();
  }

  @NotNull
  private static Couple<YaxlPsiNode> markRichLeafElements(@NotNull YaxlPsiNode node) {
    return markRichLeafElements(node, null);
  }

  @NotNull
  private static Couple<YaxlPsiNode> markRichLeafElements(@NotNull YaxlPsiNode node, @Nullable YaxlPsiNode prev) {
    if (canBeRichLeafElement(node)) {
      UserData data1 = getUserData(node);
      data1.setRichLeafElement(true);
      if (prev != null) {                     
        UserData data2 = tryGetUserData(prev);
        assert data2 != null;        
        data1.setPrevious(prev);         
        data2.setNext(node);            
      }
      return Couple.of(node, node);           
    }
        
    YaxlPsiNode first = null;
    YaxlPsiNode last = null;                        
    for (YaxlPsiNode child = node.getRealFirstChild(); child != null; child = child.getRealNextSibling()) {          
      Couple<YaxlPsiNode> couple = markRichLeafElements(child, last);
      if (first == null) first = couple.first;
      last = couple.second;
    }
    assert first != null;
    assert last != null;
    return Couple.of(first, last);
  }

  private static boolean canBeRichLeafElement(@NotNull YaxlPsiNode node) {
    YaxlData data = node.getData();
      
    if (data == null) return true;
    if (data.getMatched() != null) return true;         
    if (data.hasMatchedChild()) return false;       

    return true;       
  }         
   
  protected abstract void process(@NotNull YaxlType type, @NotNull TextRange range1, @NotNull TextRange range2);

  @NotNull
  protected abstract Couple<List<TextFragment>> finish();

  protected boolean isMoveIndependent(@NotNull YaxlPsiNode node) {
    for (YaxlPsiMoveIgnoreProvider provider : myMoveIgnoreProviders) {
      switch (provider.isMoveIndependent(node)) {
        case YES:
          return true;
        case NO:
          return false;
        case UNSURE:
      }
    }

    return false;
  }

  protected boolean isLocalMoveIndependent(@NotNull YaxlPsiNode node) {
    for (YaxlPsiLocalMoveIgnoreProvider provider : myLocalMoveIgnoreProviders) {
      switch (provider.isLocalMoveIndependent(node)) {
        case YES:
          return true;
        case NO:
          return false;
        case UNSURE:
      }
    }

    return false;
  }

  protected void processInsertion(@NotNull YaxlPsiNode node2) {
    YaxlType type = YaxlType.ONE_SIDE;
    TextRange range1 = new TextRange(myLast1, myLast1);
    TextRange range2 = node2.getElement().getTextRange();

    for (YaxlPsiFragmentListenerProvider provider : myPsiFragmentListenerProviders) {
      provider.process(type, null, node2);
    }

    process(type, range1, range2);

    myLast1 = range1.getEndOffset();
    myLast2 = range2.getEndOffset();
  }

  protected void processDeletion(@NotNull YaxlPsiNode node1) {
    YaxlType type = YaxlType.ONE_SIDE;
    TextRange range1 = node1.getElement().getTextRange();
    TextRange range2 = new TextRange(myLast2, myLast2);

    for (YaxlPsiFragmentListenerProvider provider : myPsiFragmentListenerProviders) {
      provider.process(type, node1, null);
    }

    process(type, range1, range2);

    myLast1 = range1.getEndOffset();
    myLast2 = range2.getEndOffset();
  }

  protected void processMatched(@NotNull YaxlType type, @NotNull YaxlPsiNode node1, @NotNull YaxlPsiNode node2) {
    boolean moved = YaxlType.moved(type);
    boolean modified = YaxlType.modified(type);

    for (YaxlPsiFragmentListenerProvider provider : myPsiFragmentListenerProviders) {
      provider.process(type, node1, node2);
    }

    if (modified) {
      DiffToolResult external = null;
      for (YaxlPsiExternalDiffProvider provider : myExternalDiffProviders) {
        external = provider.buildFragments(node1, node2);
        if (external != null) break;
      }

      if (external != null) {
        int size = external.getRanges1().size();

        for (int i = 0; i < size; i++) {
          YaxlType extType = external.getTypes().get(i);
          TextRange range1 = external.getRanges1().get(i);
          TextRange range2 = external.getRanges2().get(i);

          if (moved) extType = moved(extType);

          process(extType, range1, range2);
        }

        return;
      }
    }

    TextRange range1 = node1.getElement().getTextRange();
    TextRange range2 = node2.getElement().getTextRange();

    process(type, range1, range2);

    myLast1 = range1.getEndOffset();
    myLast2 = range2.getEndOffset();
  }

  private class Root {
    @NotNull private final YaxlPsiNode myRoot1;
    @NotNull private final YaxlPsiNode myRoot2;

    @NotNull private final List<YaxlPsiNode> myElements1 = new ArrayList<YaxlPsiNode>();
    @NotNull private final List<YaxlPsiNode> myElements2 = new ArrayList<YaxlPsiNode>();
    @NotNull private final List<YaxlPsiNode> myMatchedElements1 = new ArrayList<YaxlPsiNode>();

    private Root(@NotNull YaxlPsiNode root1, @NotNull YaxlPsiNode root2) {
      myRoot1 = root1;
      myRoot2 = root2;
    }

    public void process() {
      if (isRichLeafElement(myRoot1) && isRichLeafElement(myRoot2)) {
        processEqual(myRoot1, myRoot2);
        return;
      }

      collectElements1();
      collectElements2();

      markMoved();

      build();
    }

    private void markMoved() {
      List<YaxlPsiNode> matchedElements1 = new ArrayList<YaxlPsiNode>();
      List<YaxlPsiNode> matchedElements2 = new ArrayList<YaxlPsiNode>();

      for (YaxlPsiNode node1 : myMatchedElements1) {
        YaxlPsiNode node2 = getMatchedSomehow(node1);
        if (!isUnderLocalRoot2(node2)) {
          setMoved(node1, true);
          setMoved(node2, true);
          continue;
        }
        matchedElements1.add(node1);
        matchedElements2.add(node2);
      }

      //list of non-moved elements
      int[] his = calcHIS(matchedElements1, matchedElements2);

      int index = 0;
      for (int i = 0; i < matchedElements1.size(); i++) {
        if (index < his.length && his[index] == i) {
          index++;
          continue;
        }
        setMoved(matchedElements1.get(i), true);
        setMoved(matchedElements2.get(i), true);
      }
    }

    private void build() {
      int index1 = 0;
      int index2 = 0;

      while (true) {
        YaxlPsiNode node1 = index1 < myElements1.size() ? myElements1.get(index1) : null;
        YaxlPsiNode node2 = index2 < myElements2.size() ? myElements2.get(index2) : null;

        if (node1 == null && node2 == null) break;

        YaxlPsiNode matched1 = node1 == null ? null : getMatchedSomehow(node1);
        YaxlPsiNode matched2 = node2 == null ? null : getMatchedSomehow(node2);

        // This will prevent from 'matched' elements, when only one elements is rich leaf
        if (matched1 != null && !isRichLeafElement(matched1)) matched1 = null;
        if (matched2 != null && !isRichLeafElement(matched2)) matched2 = null;

        if (node1 == null) {
          if (matched2 == null) {
            processInserted(node2);
          }
          index2++;
          continue;
        }

        if (matched1 == null) {
          processDeleted(node1);

          index1++;
          continue;
        }

        if (node2 == null) {
          assert isMoved(node1);
          processMoved(node1, matched1);

          index1++;
          continue;
        }

        if (isMoved(node1)) {
          processMoved(node1, matched1);

          index1++;
          continue;
        }

        if (node2 != matched1) {
          if (matched2 == null) {
            processInserted(node2);
          }
          index2++;
          continue;
        }

        processEqual(node1, matched1);

        index1++;
        index2++;
      }
    }

    private void processInserted(@NotNull YaxlPsiNode node2) {
      YaxlDefaultPsiFragmentBuilder.this.processInsertion(node2);
    }

    private void processDeleted(@NotNull YaxlPsiNode node1) {
      YaxlDefaultPsiFragmentBuilder.this.processDeletion(node1);
    }

    private void processMoved(@NotNull YaxlPsiNode node1, @NotNull YaxlPsiNode node2) {
      if (isMoveRoot(node2) && node2 != myRoot2) {
        new Root(node1, node2).process();
        return;
      }

      boolean modified = getMatched(node1) == null;
      YaxlType type = modified ? YaxlType.MOVED_MODIFIED : YaxlType.MOVED;

      YaxlDefaultPsiFragmentBuilder.this.processMatched(type, node1, node2);
    }

    private void processEqual(@NotNull YaxlPsiNode node1, @NotNull YaxlPsiNode node2) {
      if (isMoveRoot(node2) && node2 != myRoot2) {
        new Root(node1, node2).process();
        return;
      }

      boolean modified = getMatched(node1) == null;
      YaxlType type = modified ? YaxlType.MODIFIED : YaxlType.UNCHANGED;

      YaxlDefaultPsiFragmentBuilder.this.processMatched(type, node1, node2);
    }

    private void collectElements1() {
      doCollectElements1(myRoot1, true);
    }

    private void collectElements2() {
      doCollectElements2(myRoot2);
    }

    private void doCollectElements1(@NotNull YaxlPsiNode node, boolean first) {
      if (!first) {
        YaxlPsiNode matched = getMatchedSomehow(node);
        if (matched != null && isMoveIndependentNodes(node, matched)) {
          setMoveRoot(node, true);
          setMoveRoot(matched, true);

          myElements1.add(node);
          myMatchedElements1.add(node);
          return;
        }
      }

      if (isRichLeafElement(node)) {
        YaxlPsiNode matched = getMatchedSomehow(node);
        if (matched != null && isRichLeafElement(matched)) {
          myMatchedElements1.add(node);
        }
        myElements1.add(node);
        return;
      }

      for (YaxlPsiNode child = node.getRealFirstChild(); child != null; child = child.getRealNextSibling()) {
        doCollectElements1(child, false);
      }
    }

    private void doCollectElements2(@NotNull YaxlPsiNode node) {
      if (isMoveRoot(node)) {
        myElements2.add(node);
        return;
      }

      if (isRichLeafElement(node)) {
        myElements2.add(node);
        return;
      }

      for (YaxlPsiNode child = node.getRealFirstChild(); child != null; child = child.getRealNextSibling()) {
        doCollectElements2(child);
      }
    }

    private boolean isUnderLocalRoot2(@NotNull YaxlPsiNode node) {
      YaxlPsiNode curr = node;
      while (curr != null) {
        if (curr == myRoot2) return true;
        if (isMoveRoot(curr)) return false;
        curr = curr.getParent();
      }
      return false;
    }

    private boolean isMoveIndependentNodes(@NotNull YaxlPsiNode node1, @NotNull YaxlPsiNode node2) {
      if (isMoveIndependent(node1)) return true;
      if (isMoveIndependent(node2)) return true;

      if (!isLocalMoveIndependent(node1) || !isLocalMoveIndependent(node2)) return false;

      YaxlPsiNode val1 = node1;
      YaxlPsiNode val2 = node2;

      while (val1 != myRoot1 && val2 != myRoot2 && val1 != null && val2 != null) {
        if (getMatchedSomehow(val1) != val2) {
          return false;
        }

        val1 = val1.getParent();
        val2 = val2.getParent();
      }

      return val1 == myRoot1 && val2 == myRoot2;
    }

    @NotNull
    private int[] calcHIS(@NotNull List<? extends YaxlPsiNode> elements1, @NotNull List<? extends YaxlPsiNode> elements2) {
      assert elements1.size() == elements2.size();

      int[] offsets = new int[elements1.size()];
      int[] weights = new int[elements1.size()];
      for (int i = 0; i < elements1.size(); i++) {
        YaxlPsiNode node1 = elements1.get(i);
        YaxlPsiNode node2 = elements2.get(i);

        offsets[i] = node2.getElement().getTextOffset();
        weights[i] = node1.getWeight() + node2.getWeight();
        if (isMoveRoot(node2)) weights[i] = 0;
      }

      return LISUtil.his(offsets, weights);
    }
  }

  @Nullable
  private static YaxlPsiNode getMatched(@NotNull YaxlPsiNode node) {
    YaxlData data = node.getData();
    return data == null ? null : (YaxlPsiNode)data.getMatched();
  }

  @Nullable
  private static YaxlPsiNode getMatchedSomehow(@NotNull YaxlPsiNode node) {
    YaxlData data = node.getData();
    return data == null ? null : (YaxlPsiNode)data.getMatchedSomehow();
  }

  @Nullable
  private static UserData tryGetUserData(@NotNull YaxlPsiNode node) {
    Object data = node.getUserData();
    if (data == null || !(data instanceof UserData)) return null;
    return (UserData)data;
  }

  @NotNull
  private static UserData getUserData(@NotNull YaxlPsiNode node) {
    Object data = node.getUserData();
    if (data == null || !(data instanceof UserData)) {
      data = new UserData();
      node.putUserData(data);
    }
    return (UserData)data;
  }

  private static boolean isMoved(@NotNull YaxlPsiNode node) {
    UserData data = tryGetUserData(node);
    if (data == null) return false;
    return data.isMoved();
  }

  private static boolean isRichLeafElement(@NotNull YaxlPsiNode node) {
    UserData data = tryGetUserData(node);
    if (data == null) return false;
    return data.isRichLeafElement();
  }

  private static boolean isMoveRoot(@NotNull YaxlPsiNode node) {
    UserData data = tryGetUserData(node);
    if (data == null) return false;
    return data.isMoveRoot();
  }

  private static void setMoved(@NotNull YaxlPsiNode node, boolean value) {
    UserData data = getUserData(node);
    data.setMoved(value);
  }

  private static void setRichLeafElement(@NotNull YaxlPsiNode node, boolean value) {
    UserData data = getUserData(node);
    data.setRichLeafElement(value);
  }

  private static void setMoveRoot(@NotNull YaxlPsiNode node, boolean value) {
    UserData data = getUserData(node);
    data.setMoveRoot(value);
  }

  @NotNull
  private static YaxlType moved(@NotNull YaxlType type) {
    switch (type) {
      case UNCHANGED:
        return YaxlType.MOVED;
      case ONE_SIDE:
        return YaxlType.ONE_SIDE;
      case MOVED:
        return YaxlType.MOVED;
      case MODIFIED:
        return YaxlType.MOVED_MODIFIED;
      case MOVED_MODIFIED:
        return YaxlType.MOVED_MODIFIED;
    }

    throw new IllegalStateException();
  }

  private static class UserData {
    private boolean myMoved;
    private boolean myRichLeaf;
    private boolean myMoveRoot;

    private YaxlPsiNode myPrevious;
    private YaxlPsiNode myNext;

    public boolean isMoved() {
      return myMoved;
    }

    public void setMoved(boolean value) {
      myMoved = value;
    }

    public void setRichLeafElement(boolean value) {
      myRichLeaf = value;
    }

    public boolean isRichLeafElement() {
      return myRichLeaf;
    }

    public void setMoveRoot(boolean value) {
      myMoveRoot = value;
    }

    public boolean isMoveRoot() {
      return myMoveRoot;
    }

    @Nullable
    public YaxlPsiNode getPrevious() {
      return myPrevious;
    }

    public void setPrevious(@Nullable YaxlPsiNode previous) {
      myPrevious = previous;
    }

    @Nullable
    public YaxlPsiNode getNext() {
      return myNext;
    }

    public void setNext(@Nullable YaxlPsiNode next) {
      myNext = next;
    }
  }
}