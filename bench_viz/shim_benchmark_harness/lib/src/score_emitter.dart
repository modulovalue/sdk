abstract class ScoreEmitter {
  void emit(String testName, double value);
}

class PrintEmitter implements ScoreEmitter {
  const PrintEmitter();
  @override
  void emit(String testName, double value) {
    print('$testName(RunTime): $value us.');
  }
}

abstract class ScoreEmitterV2 implements ScoreEmitter {
  @override
  void emit(String testName, double value,
      {String metric = 'RunTime', String unit});
}

class PrintEmitterV2 implements ScoreEmitterV2 {
  const PrintEmitterV2();
  @override
  void emit(String testName, double value,
      {String metric = 'RunTime', String unit = ''}) {
    print(['$testName($metric):', value, if (unit.isNotEmpty) unit].join(' '));
  }
}
