public class Main {
    public static void main(String[] args) {
        System.out.println("Hello");
    }

    private static class Inner {
        public static final int CONST_1 = 1;
        public static final int CONST_2 = 2;
    }

    public static void f1() {
        System.out.println("Hello");
        System.out.println("This");
        System.out.println("F1");
    }

    public static void f2() {
        System.out.println("Hello");
        System.out.println("This");
        System.out.println("F2");
    }
}
