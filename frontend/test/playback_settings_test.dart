import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/services/queue_service.dart';
import 'package:music_downloader/widgets/playback_settings_sheet.dart';

void main() {
  testWidgets('crossfade controls update the queue and reset to gapless',
      (tester) async {
    final queue = QueueService();
    addTearDown(queue.dispose);
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: PlaybackSettingsSheet(queue: queue))));
    expect(find.text('Off'), findsNWidgets(2));
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(6);
    await tester.pump();
    expect(queue.crossfadeDuration, const Duration(seconds: 6));
    expect(find.text('6 seconds'), findsOneWidget);
    tester.widget<Slider>(find.byType(Slider)).onChanged!(0);
    await tester.pump();
    expect(queue.crossfadeDuration, Duration.zero);
    expect(find.textContaining('gapless playback'), findsOneWidget);
  });

  test('crossfade preference bounds and change notifications', () {
    final queue = QueueService();
    addTearDown(queue.dispose);
    var changes = 0;
    queue.addListener(() => changes++);
    queue.setCrossfadeDuration(const Duration(seconds: -5));
    expect(changes, 0);
    queue.setCrossfadeDuration(const Duration(seconds: 80));
    expect(queue.crossfadeDuration, const Duration(seconds: 12));
    queue.setCrossfadeDuration(const Duration(seconds: 80));
    expect(changes, 1);
  });
}
