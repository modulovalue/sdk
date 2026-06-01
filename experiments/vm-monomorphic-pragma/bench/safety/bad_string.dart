class BitArray<@pragma('vm:monomorphic') T extends Object> {
  void add(T v) {}
}
void main() { final b = BitArray<String>(); b.add('x'); print(b); }
