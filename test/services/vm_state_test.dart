import 'package:flutter_test/flutter_test.dart';
import 'package:alpine_vm/services/vm_platform.dart';
import 'package:flutter/services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('com.ahk.linxv/vm');
  final List<MethodCall> log = <MethodCall>[];

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      log.add(methodCall);
      if (methodCall.method == 'startVm') return null;
      if (methodCall.method == 'getVmStatus') return 'running';
      return null;
    });
    log.clear();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('startVm success path updates status and isLoading', () async {
    final vmState = VmState();

    expect(vmState.status, 'stopped');
    expect(vmState.isLoading, false);

    final future = vmState.startVm();

    expect(vmState.status, 'starting');
    expect(vmState.isLoading, true);

    await future;

    expect(vmState.status, 'running');
    expect(vmState.isLoading, false);
    expect(vmState.errorMessage, isNull);
    expect(log.first.method, 'startVm');
  });

  test('stopVm resets status to stopped', () async {
    final vmState = VmState();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async => null);

    await vmState.startVm();
    await vmState.stopVm();

    expect(vmState.status, 'stopped');
    expect(vmState.isLoading, false);
  });
}
