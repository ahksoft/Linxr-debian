import 'package:flutter_test/flutter_test.dart';
import 'package:alpine_vm/services/vm_platform.dart';

void main() {
  group('VmState', () {
    test('initial password is alpine', () {
      final vmState = VmState();
      expect(vmState.sshPassword, 'alpine');
    });

    test('setting password updates sshPassword and notifies listeners', () {
      final vmState = VmState();
      var notifyCount = 0;
      vmState.addListener(() {
        notifyCount++;
      });

      vmState.setSshPassword('new-password');

      expect(vmState.sshPassword, 'new-password');
      expect(notifyCount, 1);
    });
  });
}
