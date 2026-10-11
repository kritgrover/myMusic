import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/models/queue_item.dart';
import 'package:music_downloader/services/queue_service.dart';
import 'package:music_downloader/widgets/queue_panel.dart';

void main() {
  testWidgets('last queue entry explains the current repeat mode',
      (tester) async {
    final queue = QueueService();
    addTearDown(queue.dispose);
    queue.addToQueue(QueueItem(id: 'current', title: 'Current track'));
    queue.setCurrentIndex(0);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: QueuePanel(queueService: queue, onClose: () {})),
    ));
    const off = 'Nothing queued next. Add a song or turn on repeat.';
    const all = 'The queue will repeat when this track ends.';
    const single = 'This track will repeat.';
    expect(queue.loopMode, LoopMode.none);
    expect(find.text(off), findsOneWidget);
    expect(find.text(all), findsNothing);
    expect(find.text(single), findsNothing);

    queue.toggleLoopMode();
    await tester.pump();
    expect(queue.loopMode, LoopMode.queue);
    expect(find.text(all), findsOneWidget);
    expect(find.text(off), findsNothing);

    queue.toggleLoopMode();
    await tester.pump();
    expect(queue.loopMode, LoopMode.single);
    expect(find.text(single), findsOneWidget);
    expect(find.text(all), findsNothing);
    expect(find.text(off), findsNothing);

    queue.toggleLoopMode();
    await tester.pump();
    expect(find.text(off), findsOneWidget);
    expect(find.text(single), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
