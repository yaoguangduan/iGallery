import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
// RenderMetaData 不在 widgets/basic.dart 那份 rendering 白名单里
// （RenderBox 在，所以只有它报错），命中判定要用就得显式引 rendering
import 'package:flutter/rendering.dart';

/// 滑动多选。相册网格和上传选择器共用这一套。只在多选模式下启用。
///
/// **两条触发路径，都指向同一套 sweep 回调：**
///
/// 1. **横向起手 = 立即滑选**（主路径，`HorizontalDragGestureRecognizer`）。
///    手指落在格子上往横向一带就开始选，零延迟。之所以能和滚动共存，靠的是
///    Flutter 竞技场的**轴向消歧**：横向移动横向识别器赢，纵向移动 ScrollView
///    的 VerticalDrag 赢。一旦横向识别器接管了这根指针，后续往任意方向
///    （包括纵向）移动都继续滑选 —— 于是"右滑一行再往下一行行选"是通的。
///
/// 2. **按住不动再拖 = 滑选**（补充路径，`DelayedMultiDragGestureRecognizer`
///    160ms）。给那种想从纵向直接开始选的操作留一条路。
///
/// 只留第 2 条是不够的：它要求手指先静止 160ms，落下即滑会被判成滚动而让位，
/// 体感就是"滑选根本没反应"。也不能只留第 1 条：纯纵向的选择需求会没法表达。
///
/// 不要退回 `GestureDetector.onLongPressStart/MoveUpdate`：那套要等 500ms，
/// 且期间任何移动都被 scroll 抢走，等于永远触发不了。
///
/// 命中判定走 **hit-test 找 [DragSelectItem]**，不做网格几何换算：
/// 几何换算要求调用方的 gridDelegate 参数和这里的常量永远一致，
/// 而且在 CustomScrollView 多 sliver（文件夹区 + 按天分组的多个网格）下根本算不出来。
class DragSelectDetector extends StatefulWidget {
  final Widget child;

  /// 关掉时完全不注册 recognizer，滚动手感不受任何影响
  final bool enabled;

  /// 按住的第一个条目。返回 true 表示接管这次拖动，false 则让给滚动
  final bool Function(int index) onStart;

  /// 拖过的条目（含快速滑动时补齐的中间项）
  final void Function(int index) onEnter;

  final VoidCallback? onEnd;

  /// 传了就启用边缘自动滚动，滑到屏幕上下边缘时继续翻
  final ScrollController? scrollController;

  const DragSelectDetector({
    super.key,
    required this.child,
    required this.onStart,
    required this.onEnter,
    this.onEnd,
    this.enabled = true,
    this.scrollController,
  });

  @override
  State<DragSelectDetector> createState() => _DragSelectDetectorState();
}

class _DragSelectDetectorState extends State<DragSelectDetector> {
  int? _lastIndex;
  Timer? _autoScroll;
  double _pendingDelta = 0;
  Offset? _lastPointer;

  // 边缘自动滚动
  static const double _edge = 90;      // 触发区高度
  static const double _maxStep = 26;   // 每 tick 最多滚多少

  @override
  void dispose() {
    _stopAutoScroll();
    super.dispose();
  }

  /// 命中测试：从最内层往外找第一个 DragSelectItem 的下标
  int? _indexAt(Offset globalPosition) {
    final view = View.maybeOf(context);
    if (view == null) return null;
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, globalPosition, view.viewId);
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData) {
        final meta = target.metaData;
        if (meta is _DragSelectTag) return meta.index;
      }
    }
    return null;
  }

  /// 两条路径共用的起手逻辑。返回是否真的开始了滑选。
  bool _begin(Offset globalPosition) {
    final idx = _indexAt(globalPosition);
    if (idx == null) return false;
    if (!widget.onStart(idx)) return false;
    _lastIndex = idx;
    return true;
  }

  void _finish() {
    if (_lastIndex == null) return;   // 没起手过，别误发 onEnd
    _stopAutoScroll();
    _lastIndex = null;
    widget.onEnd?.call();
  }

  // 路径 1：横向起手
  void _onHorizontalStart(DragStartDetails d) => _begin(d.globalPosition);

  void _onHorizontalUpdate(DragUpdateDetails d) {
    if (_lastIndex == null) {
      // 起手时落在空隙上，滑到格子上再补开始
      _begin(d.globalPosition);
      return;
    }
    _onDragUpdate(d.globalPosition);
  }

  // 路径 2：按住不动再拖
  Drag? _onDelayedDragStart(Offset globalPosition) {
    if (!_begin(globalPosition)) return null;
    return _SelectDrag(onUpdate: _onDragUpdate, onDone: _finish);
  }

  void _onDragUpdate(Offset globalPosition) {
    final idx = _indexAt(globalPosition);
    if (idx != null) {
      final last = _lastIndex;
      if (last == null || idx == last) {
        widget.onEnter(idx);
      } else {
        // 快速滑动时指针事件是稀疏的，中间格子会被跳过 —— 补齐，
        // 否则"一行一行往下选"会漏掉一片
        final step = idx > last ? 1 : -1;
        for (var i = last + step;; i += step) {
          widget.onEnter(i);
          if (i == idx) break;
        }
      }
      _lastIndex = idx;
    }
    _tickAutoScroll(globalPosition);
  }

  // ── 边缘自动滚动 ──

  void _tickAutoScroll(Offset globalPosition) {
    final ctrl = widget.scrollController;
    final box = context.findRenderObject() as RenderBox?;
    if (ctrl == null || box == null || !ctrl.hasClients) return;

    final local = box.globalToLocal(globalPosition);
    final h = box.size.height;
    double delta = 0;
    if (local.dy < _edge) {
      delta = -_maxStep * (1 - local.dy / _edge).clamp(0.0, 1.0);
    } else if (local.dy > h - _edge) {
      delta = _maxStep * (1 - (h - local.dy) / _edge).clamp(0.0, 1.0);
    }

    if (delta == 0) { _stopAutoScroll(); return; }

    _autoScroll ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      final c = widget.scrollController;
      if (c == null || !c.hasClients) { _stopAutoScroll(); return; }
      final target = (c.offset + _pendingDelta)
          .clamp(c.position.minScrollExtent, c.position.maxScrollExtent);
      if (target == c.offset) return;
      c.jumpTo(target);
      // 手指没动但内容在动，命中的格子也在变 —— 用最后已知的指针位置重新判定
      final p = _lastPointer;
      if (p != null) {
        final idx = _indexAt(p);
        if (idx != null && idx != _lastIndex) {
          widget.onEnter(idx);
          _lastIndex = idx;
        }
      }
    });
    _pendingDelta = delta;
    _lastPointer = globalPosition;
  }

  void _stopAutoScroll() {
    _autoScroll?.cancel();
    _autoScroll = null;
    _pendingDelta = 0;
  }

  @override
  Widget build(BuildContext context) {
    // 无论 enabled 与否都渲染 RawGestureDetector，只切换 gestures 内容。
    //
    // 千万别写成 `if (!enabled) return child;` —— 那样 enabled 翻转时
    // child 的父节点类型变了，element 会被卸载重建，
    // 里面 CustomScrollView 的滚动位置直接丢失（表现为"进多选就跳到顶部"）。
    // 空 map 本身没有任何开销，识别器不会被创建。
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: widget.enabled
          ? <Type, GestureRecognizerFactory>{
              // 路径 1：横向起手立即滑选。和 ScrollView 的 VerticalDrag 靠轴向消歧共存
              HorizontalDragGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<HorizontalDragGestureRecognizer>(
                HorizontalDragGestureRecognizer.new,
                (r) {
                  r.onStart = _onHorizontalStart;
                  r.onUpdate = _onHorizontalUpdate;
                  r.onEnd = (_) => _finish();
                  r.onCancel = _finish;
                },
              ),
              // 路径 2：按住 120ms 再拖，方向不限
              DelayedMultiDragGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<DelayedMultiDragGestureRecognizer>(
                () => DelayedMultiDragGestureRecognizer(
                  delay: const Duration(milliseconds: 120),
                ),
                (r) => r.onStart = _onDelayedDragStart,
              ),
            }
          : const <Type, GestureRecognizerFactory>{},
      child: widget.child,
    );
  }
}

/// 包住每个可滑选的格子，把下标埋进 render 树供 hit-test 找到。
/// 用 [MetaData] 而不是 GlobalKey：GlobalKey 每格一个在几千项的网格上太贵。
class DragSelectItem extends StatelessWidget {
  final int index;
  final Widget child;
  const DragSelectItem({super.key, required this.index, required this.child});

  @override
  Widget build(BuildContext context) {
    return MetaData(
      metaData: _DragSelectTag(index),
      behavior: HitTestBehavior.translucent,
      child: child,
    );
  }
}

/// 私有标记类型，避免和别处塞进 MetaData 的东西混淆
class _DragSelectTag {
  final int index;
  const _DragSelectTag(this.index);
}

class _SelectDrag extends Drag {
  final void Function(Offset globalPosition) onUpdate;
  final VoidCallback onDone;
  _SelectDrag({required this.onUpdate, required this.onDone});

  @override
  void update(DragUpdateDetails details) => onUpdate(details.globalPosition);

  @override
  void end(DragEndDetails details) => onDone();

  @override
  void cancel() => onDone();
}
