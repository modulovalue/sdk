extension type const NodeId(int value) implements int {}
extension type const Pid(NodeId raw) implements int {}   // ext-over-ext-over-int
class BitSet<@pragma('vm:monomorphic') T extends int> {
  int n = 0;
  void add(T v) { n ^= v; }
}
void main() {
  final a = BitSet<int>()..add(1);
  final b = BitSet<NodeId>()..add(NodeId(2));
  final c = BitSet<Pid>()..add(Pid(NodeId(3)));
  print('${a.n} ${b.n} ${c.n}');
}
