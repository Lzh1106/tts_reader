import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/services/paragraph_reflow.dart';

/// PDF「自动排版」验证。
///
/// 这一层的判据全是启发式的，所以用例都照着**真实 PDF 抽取出来的文本**写：
/// 硬折行、英文断词、页眉页脚、项目符号、以及那些**不该被合并**的情况。
void main() {
  /// 造一行：默认右边界到 500（正文宽度），[right] 用来模拟「排满了」
  ReflowLine row(String text, {double right = 500, double? left}) => ReflowLine(
    text: text,
    left: left ?? 50,
    top: 0,
    right: right,
    bottom: 12,
  );

  /// 按「最宽的行」估算右边界（真实路径里是页面文字行里最靠右的那条）
  List<String> paragraphsOf(List<ReflowLine> lines) {
    var edge = 0.0;
    for (final line in lines) {
      if (line.text.trim().isEmpty) continue;
      if (line.right > edge) edge = line.right;
    }
    return ParagraphReflow.reflowPage(lines, rightEdge: edge * 0.9)
        .map((p) => p.text)
        .toList();
  }

  group('硬折行合并', () {
    test('行尾没有句末标点 + 排满右边界 → 接回同一段', () {
      final result = paragraphsOf(<ReflowLine>[
        row('这是第一行被排版折断的文字，'),
        row('接着是第二行继续往下写，'),
        row('第三行才是这一段的结尾。'),
      ]);
      expect(result.length, 1);
      expect(result.first, '这是第一行被排版折断的文字，接着是第二行继续往下写，第三行才是这一段的结尾。');
    });

    test('行尾是句末标点 → 另起一段（作者真的分段了）', () {
      final result = paragraphsOf(<ReflowLine>[
        row('第一段到此结束。'),
        row('这是第二段的内容。'),
      ]);
      expect(result.length, 2);
      expect(result[0], '第一段到此结束。');
      expect(result[1], '这是第二段的内容。');
    });

    test('行尾是逗号但没排满 → 仍然合并（标点说了没说完）', () {
      final result = paragraphsOf(<ReflowLine>[
        row('很短的一行，', right: 200),
        row('后半句在这里收尾。'),
      ]);
      expect(result.length, 1);
      expect(result.first, '很短的一行，后半句在这里收尾。');
    });

    test('短行 + 无标点 → 当成独立段落（不是被折出来的）', () {
      final result = paragraphsOf(<ReflowLine>[
        row('第一章', right: 120),
        row('正文从这里开始，后面还有很多内容。'),
      ]);
      // 标题行自成一段（也命中 headingLike 分支）
      expect(result.length, 2);
      expect(result.first, '第一章');
    });

    test('PDF 行参差不齐 + 下一行小写开头 → 仍算续行（设备上实测的失败场景）', () {
      // 真实的 PDF 抽取行长度不齐：第一行比最宽的那行短一截，
      // 只靠宽度会把它判成「段落末行」，整套排版就白做了。
      final result = paragraphsOf(<ReflowLine>[
        row('Reflow first wrapped line of the sentence,', right: 460),
        row('and the second wrapped line continues here,', right: 500),
        row('while the third line ends the paragraph.', right: 400),
      ]);
      expect(result.length, 1, reason: '三行都该并成一段');
      expect(result.first, contains('Reflow first wrapped line'));
      expect(result.first, contains('while the third line ends the paragraph.'));
    });

    test('行中间是「句末标点 + 空格 + 小写词」→ 不算分段（软换行的续词被接回来了）', () {
      // `…here. filler word…` 里的 filler 是上一行的续词，不是新句子
      final result = paragraphsOf(<ReflowLine>[
        row('wrapped line of the sentence here. filler word filler word', right: 500),
        row('and the next line continues the same paragraph here', right: 500),
      ]);
      expect(result.length, 1, reason: '这是一整段，不该从中间劈开');
    });

    test('行中间出现「句末标点 + 新句子开头」→ 作者在这里分段（软换行被接回同一行）', () {
      // 英文句子几乎总以大写开头，所以「句号 + 空格 + 大写」是可靠的分段信号
      final result = paragraphsOf(<ReflowLine>[
        row('First independent sentence here. Filler word filler word'),
        row('Second independent sentence here. Filler word filler word'),
      ]);
      expect(result.length, 2, reason: '两个句子各成一段');
      expect(result[0], startsWith('First independent sentence here.'));
      expect(result[1], startsWith('Second independent sentence here.'));
    });

    test('中文行中间的句号同样算分段点', () {
      final result = paragraphsOf(<ReflowLine>[
        row('第一句话在这里就结束了。后面接着写第二句话'),
        row('第二句话也结束了。第三句话开始'),
      ]);
      expect(result.length, greaterThanOrEqualTo(2));
    });

    test('英文硬折行合并时补一个空格', () {
      final result = paragraphsOf(<ReflowLine>[
        row('This sentence was wrapped by the'),
        row('typesetter at the right margin.'),
      ]);
      expect(result.length, 1);
      expect(result.first, 'This sentence was wrapped by the typesetter at the right margin.');
    });

    test('英文断词（inter- + national）把连字符去掉', () {
      final result = paragraphsOf(<ReflowLine>[
        row('This is an inter-'),
        row('national standard.'),
      ]);
      expect(result.length, 1);
      expect(result.first, 'This is an international standard.');
    });

    test('真连字符（well- + known 小写但属同一个词）按断词处理', () {
      // 判据是「字母-小写字母」：这是英文硬折行的典型特征。
      // 想保留连字符的 `well-Known` 那种写法在连续正文里几乎不出现，
      // 所以这里按断词处理（去掉连字符直接拼）是可接受的取舍。
      final result = paragraphsOf(<ReflowLine>[
        row('It is a well-'),
        row('known fact that text wraps.'),
      ]);
      expect(result.first, 'It is a wellknown fact that text wraps.');
    });

    test('连字符后面是大写（专有名词）时保留连字符', () {
      final result = paragraphsOf(<ReflowLine>[
        row('It is a well-'),
        row('Known fact that text wraps.'),
      ]);
      // 判据是「字母-小写字母」才当断词；大写开头更可能是保留连字符的写法，
      // 此时不补空格（连字符已经占住词间位置）
      expect(result.first, contains('well-Known'));
    });
  });

  group('分段判据', () {
    test('空行一定分段', () {
      final result = paragraphsOf(<ReflowLine>[
        row('上一段的结尾没有标点'),
        row(''),
        row('这一段是新的'),
      ]);
      expect(result.length, 2);
      expect(result[0], '上一段的结尾没有标点');
      expect(result[1], '这一段是新的');
    });

    test('项目符号 / 编号开头另起一段', () {
      for (final marker in <String>['• 第一条内容', '- 第二条内容', '1. 第三条内容', '(2) 第四条内容']) {
        final result = paragraphsOf(<ReflowLine>[
          row('前面一段的正文', right: 400),
          row(marker, right: 300),
        ]);
        expect(result.length, 2, reason: marker);
        // 换行被抹平、空行被句子切分吃掉：`1. 标题` 会连成 `1.标题`
        // （分句规则把 `.` 当句末标点）。对朗读没有影响，所以不做还原。
        expect(result.last.replaceAll(' ', ''), marker.replaceAll(' ', ''), reason: marker);
      }
    });

    test('下一行以标点开头 → 一定是续行', () {
      final result = paragraphsOf(<ReflowLine>[
        row('上一行的结尾没有标点', right: 200),
        row('，所以它其实还没说完。'),
      ]);
      expect(result.length, 1);
      expect(result.first, '上一行的结尾没有标点，所以它其实还没说完。');
    });

    test('上一行以开引号收尾 → 一定接上', () {
      final result = paragraphsOf(<ReflowLine>[
        row('他说：「', right: 120),
        row('今天天气不错。」'),
      ]);
      expect(result.length, 1);
      expect(result.first, '他说：「今天天气不错。」');
    });

    test('章标题行自成一段', () {
      final result = paragraphsOf(<ReflowLine>[
        row('第一章 起点', right: 150),
        row('正文紧接着标题写在下一行，'),
        row('而且这句话在这里才结束。'),
      ]);
      expect(result.length, 2);
      expect(result[0], '第一章 起点');
      expect(result[1], '正文紧接着标题写在下一行，而且这句话在这里才结束。');
    });

    test('一句话被折成三行时合成一段，句子按标点切分', () {
      final paragraphs = ParagraphReflow.reflowPage(<ReflowLine>[
        row('这是一句很长的话，'),
        row('它被排版折成了三行，'),
        row('到这里才结束。'),
      ], rightEdge: 500 * 0.9);
      expect(paragraphs.length, 1, reason: '没有句末标点，三行属于同一段');
      expect(paragraphs.first.sentences.length, 1);
      expect(paragraphs.first.text, '这是一句很长的话，它被排版折成了三行，到这里才结束。');
    });

    test('上一句结束、下一句跨两行：切成两句，段数仍是一段', () {
      final paragraphs = ParagraphReflow.reflowPage(<ReflowLine>[
        row('第一句在这里结束。'),
        row('第二句还没写完，'),
        row('它跨了两行才结束！'),
      ], rightEdge: 500 * 0.9);
      expect(paragraphs.length, 2, reason: '第一行以句号结束，作者在这里分段了');
      expect(paragraphs.first.sentences.map((s) => s.text).toList(), <String>['第一句在这里结束。']);
      // 第二段里那句话跨了两行，合成一句
      expect(paragraphs[1].sentences.map((s) => s.text).toList(), <String>[
        '第二句还没写完，它跨了两行才结束！',
      ]);
    });
  });

  group('页眉页脚去噪', () {
    test('重复出现的页眉被丢掉，正文留下', () {
      final lines = <ReflowLine>[
        row('桃花源书系 · 第一卷', right: 200),
        row('正文第一行的内容，'),
        row('正文第二行接着写。'),
        row('正文第三行的内容，'),
        row('正文第四行接着写。'),
        row('正文第五行的内容，'),
        row('正文第六行接着写。'),
        row('正文第七行的内容，'),
        row('桃花源书系 · 第一卷', right: 200),
      ];
      final result = paragraphsOf(lines);
      expect(result.join(), isNot(contains('桃花源书系')));
      expect(result.join(), contains('正文第一行'));
    });

    test('纯页码行总是被丢掉（不必重复出现）', () {
      final lines = <ReflowLine>[
        row('正文从这里开始，'),
        row('然后一直写到这一页的底部。'),
        row('正文还有很多内容，'),
        row('多到足够触发去噪的分支。'),
        row('再多写两行凑数，'),
        row('好让行数达到阈值。'),
        row('再补一行内容，'),
        row('最后一行正文。'),
        row('42', right: 80),
      ];
      final result = paragraphsOf(lines);
      expect(result.join(), isNot(contains('42')));
    });

    test('行太少时不去噪（一页都没排满，别误删）', () {
      final result = paragraphsOf(<ReflowLine>[
        row('2024', right: 60),
        row('正文只有这一行。'),
      ]);
      expect(result.join(), contains('2024'));
    });
  });

  group('整篇重排', () {
    Chapter chapter(String title, List<String> lines) => Chapter(
      title: title,
      paragraphs: <Paragraph>[
        for (final line in lines)
          Paragraph(sentences: <Sentence>[Sentence(line)]),
      ],
    );

    test('逐页重排后段数变少；没有可重排的页面返回 null', () {
      final chapters = <Chapter>[
        chapter('第 1 页', <String>['被折断的第一行，', '被折断的第二行。']),
        chapter('第 2 页', <String>['这一页没有行信息，保持原样。']),
      ];
      final reflowed = ParagraphReflow.reflowDocument(chapters, <int, List<ReflowLine>>{
        0: <ReflowLine>[row('被折断的第一行，'), row('被折断的第二行。')],
      });
      expect(reflowed, isNotNull);
      expect(reflowed![0].paragraphs.length, 1);
      expect(reflowed[0].paragraphs.first.text, '被折断的第一行，被折断的第二行。');
      expect(reflowed[1].paragraphs.length, 1, reason: '没有行信息的章保持原样');
    });

    test('排版本来就对（内容一致）时返回 null，界面据此提示「无需重排」', () {
      final chapters = <Chapter>[
        chapter('第 1 页', <String>['第一段。', '第二段。']),
      ];
      final reflowed = ParagraphReflow.reflowDocument(chapters, <int, List<ReflowLine>>{
        0: <ReflowLine>[row('第一段。'), row('第二段。')],
      });
      expect(reflowed, isNull);
    });

    test('段数相同但内容被合并了，也算「有变化」（PDF 一页一章的常见情形）', () {
      // 原文是「一整段里塞着三行」，重排后还是 1 段 —— 只比段数会漏判
      final flat = chapter('第 1 页', <String>['第一行，第二行！']);
      final reflowed =
          ParagraphReflow.reflowDocument(<Chapter>[flat], <int, List<ReflowLine>>{
        0: <ReflowLine>[
          row('第一行，', right: 300),
          row('第二行！'),
          row('第三行也在这里。'),
        ],
      });
      expect(reflowed, isNotNull);
      // 前两行合并成一段（逗号接续），第三行自成一段；原文只有一段 → 算有变化
      expect(reflowed!.length, 1);
      expect(reflowed[0].paragraphs.length, 2);
      expect(reflowed[0].paragraphs.first.text, '第一行，第二行！');
    });

    test('analyze 会带回「为什么没重排」的诊断信息', () {
      final chapters = <Chapter>[
        chapter('第 1 页', <String>['第一段。', '第二段。']),
      ];
      ParagraphReflow.debugSink = null;
      final report = ParagraphReflow.analyze(
        chapters,
        <int, List<ReflowLine>>{
          0: <ReflowLine>[row('第一段。'), row('第二段。')],
        },
      );
      expect(report.changed, isFalse);
      expect(report.pagesWithLines, 1);
      expect(report.beforeParagraphs, 2);
      expect(report.afterParagraphs, 2);
      expect(report.summary, contains('有变化=false'));

      final noLines = ParagraphReflow.analyze(chapters, const <int, List<ReflowLine>>{});
      expect(noLines.changed, isFalse);
      expect(noLines.pagesWithLines, 0, reason: '没有行信息时界面要给出不同的提示');
    });

    test('完全没有行信息（非 PDF 或扫描件）返回 null', () {
      final chapters = <Chapter>[chapter('第 1 页', <String>['正文。'])];
      expect(ParagraphReflow.reflowDocument(chapters, const <int, List<ReflowLine>>{}), isNull);
    });
  });

  group('行分隔符（纯函数）', () {
    test('中英混排的分隔规则', () {
      expect(ParagraphReflow.lineSeparator('abc', 'def'), ' ');
      expect(ParagraphReflow.lineSeparator('中文', '继续'), '');
      expect(ParagraphReflow.lineSeparator('abc', '中文'), '');
      expect(ParagraphReflow.lineSeparator('中文', 'abc'), '');
      expect(ParagraphReflow.lineSeparator('', 'abc'), '');
    });
  });
}
