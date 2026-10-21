import 'dart:math';

import 'package:sync_engine/sync_engine.dart';
import 'package:test/test.dart';

void main() {
  group('local editing', () {
    test('typing, middle insert, and delete read back correctly', () {
      final a = CrdtText('a');
      a.insertTextAt(0, 'hello');
      expect(a.text, 'hello');
      a.insertAt(5, '!');
      expect(a.text, 'hello!');
      a.deleteAt(0);
      expect(a.text, 'ello!');
      expect(a.length, 5);
      // Tombstone keeps structural count.
      expect(a.nodeCount, 6);
    });

    test('insertAt rejects multi-rune strings and bad indexes', () {
      final a = CrdtText('a');
      expect(() => a.insertAt(0, 'ab'), throwsArgumentError);
      expect(() => a.insertAt(3, 'x'), throwsRangeError);
      expect(() => a.deleteAt(0), throwsRangeError);
    });

    test('emoji are single runes', () {
      final a = CrdtText('a');
      a.insertTextAt(0, 'a😀b');
      expect(a.length, 3);
      a.deleteAt(1);
      expect(a.text, 'ab');
    });
  });

  group('convergence', () {
    test('concurrent inserts at the head converge; documented order', () {
      final a = CrdtText('a');
      final b = CrdtText('b');
      final opA = a.insertAt(0, 'A'); // id a:1, parent null
      final opB = b.insertAt(0, 'B'); // id b:1, parent null
      a.merge(<CrdtOp>[opB]);
      b.merge(<CrdtOp>[opA]);
      // Sibling rule: descending (counter, siteId) -> b:1 before a:1.
      expect(a.text, 'BA');
      expect(b.text, 'BA');
    });

    test('offline edits on a shared base converge in both exchange orders',
        () {
      final a = CrdtText.withText('a', 'hello');
      final b = CrdtText('b')..merge(a.allOps);
      expect(b.text, 'hello');

      // A appends '!'; B replaces 'h' with 'H' (delete + head insert).
      final aOps = <CrdtOp>[a.insertAt(5, '!')];
      final bOps = <CrdtOp>[b.deleteAt(0), b.insertAt(0, 'H')];

      // Order 1: A learns B's ops, B learns A's ops.
      a.merge(bOps);
      b.merge(aOps);
      expect(a.text, 'Hello!');
      expect(b.text, 'Hello!');

      // Order 2: fresh replicas replaying the same op sets reversed.
      final c = CrdtText('c')..merge(a.allOps);
      final d = CrdtText('d')..merge(b.allOps);
      expect(c.text, 'Hello!');
      expect(d.text, c.text);
    });

    test('concurrent inserts in the middle interleave deterministically',
        () {
      final base = CrdtText.withText('s', 'ac');
      final a = CrdtText('a')..merge(base.allOps);
      final b = CrdtText('b')..merge(base.allOps);
      // Both insert between 'a' and 'c' (parent = the 'a' node s:1).
      final opA = a.insertAt(1, 'A'); // a:1
      final opB = b.insertAt(1, 'B'); // b:1, same parent, higher siteId
      a.merge(<CrdtOp>[opB]);
      b.merge(<CrdtOp>[opA]);
      expect(a.text, 'aBAc');
      expect(b.text, 'aBAc');
    });

    test('merge is idempotent, including self-merge', () {
      final a = CrdtText.withText('a', 'abc');
      final ops = a.allOps;
      final b = CrdtText('b');
      expect(b.merge(ops), 3);
      expect(b.merge(ops), 0); // second application: no change
      expect(b.text, 'abc');
      expect(a.merge(a.allOps), 0);
      final del = a.deleteAt(1);
      expect(b.merge(<CrdtOp>[del]), 1);
      expect(b.merge(<CrdtOp>[del]), 0);
      expect(b.text, 'ac');
    });

    test('out-of-order delivery is buffered, not lost', () {
      final a = CrdtText('a');
      final first = a.insertAt(0, 'x');
      final second = a.insertAt(1, 'y'); // parent = first.id

      final b = CrdtText('b');
      b.merge(<CrdtOp>[second]); // parent unknown yet
      expect(b.pendingCount, 1);
      expect(b.text, '');
      b.merge(<CrdtOp>[first]);
      expect(b.pendingCount, 0);
      expect(b.text, 'xy');

      // Delete arriving before its target insert.
      final del = a.deleteAt(0);
      final c = CrdtText('c');
      c.merge(<CrdtOp>[del]);
      expect(c.pendingCount, 1);
      c.merge(<CrdtOp>[first, second]);
      expect(c.pendingCount, 0);
      expect(c.text, 'y');
    });

    test('property-style: seeded random concurrent edits converge', () {
      final rng = Random(42);
      final base = CrdtText.withText('s', 'seed');
      final a = CrdtText('a')..merge(base.allOps);
      final b = CrdtText('b')..merge(base.allOps);
      final aOps = <CrdtOp>[];
      final bOps = <CrdtOp>[];

      void randomEdits(CrdtText site, List<CrdtOp> sink, int count) {
        const alphabet = 'xyz01 ';
        for (var i = 0; i < count; i++) {
          if (site.length == 0 || rng.nextBool()) {
            final at = rng.nextInt(site.length + 1);
            final ch = alphabet[rng.nextInt(alphabet.length)];
            sink.add(site.insertAt(at, ch));
          } else {
            sink.add(site.deleteAt(rng.nextInt(site.length)));
          }
        }
      }

      randomEdits(a, aOps, 60);
      randomEdits(b, bOps, 60);

      // Originals cross-merge.
      a.merge(bOps);
      b.merge(aOps);
      expect(a.text, b.text);

      // Fresh replicas receiving the same sets in different shuffled
      // orders must land on the identical string.
      final shuffledA = <CrdtOp>[...aOps]..shuffle(Random(7));
      final shuffledB = <CrdtOp>[...bOps]..shuffle(Random(9));
      final r1 = CrdtText('r1')
        ..merge(base.allOps)
        ..merge(shuffledA)
        ..merge(shuffledB);
      final r2 = CrdtText('r2')
        ..merge(base.allOps)
        ..merge(shuffledB.reversed)
        ..merge(shuffledA.reversed);
      expect(r1.text, a.text);
      expect(r2.text, a.text);
      expect(r1.pendingCount, 0);
      expect(r2.pendingCount, 0);
    });
  });
}
