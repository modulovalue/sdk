extension type Money(double cents) {}
class Bag<@pragma('vm:monomorphic') T extends num> { void add(T v) {} }
void main() { final b = Bag<Money>(); print(b); }
