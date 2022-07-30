import 'package:diffutil_dart/diffutil.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;

import '../models/date_header.dart';
import '../models/message_spacer.dart';
import 'inherited_chat_theme.dart';
import 'inherited_user.dart';

/// Animated list that handles automatic animations and pagination.
class ChatList extends StatefulWidget {
  /// Creates a chat list widget.
  const ChatList({
    super.key,
    this.isLastPage,
    required this.itemBuilder,
    required this.items,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
    this.onEndReached,
    this.onEndReachedThreshold,
    this.scrollController,
    this.scrollPhysics,
  });

  /// Used for pagination (infinite scroll) together with [onEndReached].
  /// When true, indicates that there are no more pages to load and
  /// pagination will not be triggered.
  final bool? isLastPage;

  /// Item builder.
  final Widget Function(Object, int? index) itemBuilder;

  /// Items to build.
  final List<Object> items;

  /// Used for pagination (infinite scroll). Called when user scrolls
  /// to the very end of the list (minus [onEndReachedThreshold]).
  final Future<void> Function()? onEndReached;

  /// A representation of how a [ScrollView] should dismiss the on-screen keyboard.
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;

  /// Used for pagination (infinite scroll) together with [onEndReached].
  /// Can be anything from 0 to 1, where 0 is immediate load of the next page
  /// as soon as scroll starts, and 1 is load of the next page only if scrolled
  /// to the very end of the list. Default value is 0.75, e.g. start loading
  /// next page when scrolled through about 3/4 of the available content.
  final double? onEndReachedThreshold;

  /// Used to control the chat list scroll view.
  final ScrollController? scrollController;

  /// Determines the physics of the scroll view.
  final ScrollPhysics? scrollPhysics;

  @override
  State<ChatList> createState() => _ChatListState();
}

/// [ChatList] widget state.
class _ChatListState extends State<ChatList>
    with SingleTickerProviderStateMixin {
  late final Animation<double> _animation = CurvedAnimation(
    curve: Curves.easeOutQuad,
    parent: _controller,
  );

  late final AnimationController _controller = AnimationController(vsync: this);

  bool _isNextPageLoading = false;
  final GlobalKey<SliverAnimatedListState> _listKey =
      GlobalKey<SliverAnimatedListState>();
  late List<Object> _oldData = List.from(widget.items);
  late ScrollController _scrollController;

  @override
  void initState() {
    super.initState();

    _scrollController = widget.scrollController ?? ScrollController();
    didUpdateWidget(widget);
  }

  @override
  void didUpdateWidget(covariant ChatList oldWidget) {
    super.didUpdateWidget(oldWidget);

    _calculateDiffs(oldWidget.items);
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (widget.onEndReached == null || widget.isLastPage == true) {
            return false;
          }

          if (notification.metrics.pixels >=
              (notification.metrics.maxScrollExtent *
                  (widget.onEndReachedThreshold ?? 0.75))) {
            if (widget.items.isEmpty || _isNextPageLoading) return false;

            _controller.duration = Duration.zero;
            _controller.forward();

            setState(() {
              _isNextPageLoading = true;
            });

            widget.onEndReached!().whenComplete(() {
              _controller.duration = const Duration(milliseconds: 300);
              _controller.reverse();

              setState(() {
                _isNextPageLoading = false;
              });
            });
          }

          return false;
        },
        child: CustomScrollView(
          controller: _scrollController,
          keyboardDismissBehavior: widget.keyboardDismissBehavior,
          physics: widget.scrollPhysics,
          reverse: true,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.only(bottom: 4),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final item = widget.items[index];
                    if (item is Map<String, Object>) {
                      return AnimatedMessage(
                        key: _valueKeyForItem(item),
                        child: widget.itemBuilder(item, index),
                      );
                    }
                    return widget.itemBuilder(item, index);
                  },
                  findChildIndexCallback: (Key key) {
                    if (key is ValueKey<Object>) {
                      final newIndex = widget.items.indexWhere(
                        (v) => _valueKeyForItem(v) == key,
                      );
                      if (newIndex != -1) {
                        return newIndex;
                      }
                    }
                    return null;
                  },
                  childCount: widget.items.length,
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.only(
                top: 16 + (kIsWeb ? 0 : MediaQuery.of(context).padding.top),
              ),
              sliver: SliverToBoxAdapter(
                child: SizeTransition(
                  axisAlignment: 1,
                  sizeFactor: _animation,
                  child: Center(
                    child: Container(
                      alignment: Alignment.center,
                      height: 32,
                      width: 32,
                      child: SizedBox(
                        height: 16,
                        width: 16,
                        child: _isNextPageLoading
                            ? CircularProgressIndicator(
                                backgroundColor: Colors.transparent,
                                strokeWidth: 1.5,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  InheritedChatTheme.of(context)
                                      .theme
                                      .primaryColor,
                                ),
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );

  void _calculateDiffs(List<Object> oldList) async {
    final diffResult = calculateListDiff<Object>(
      oldList,
      widget.items,
      equalityChecker: (item1, item2) {
        if (item1 is Map<String, Object> && item2 is Map<String, Object>) {
          final message1 = item1['message']! as types.Message;
          final message2 = item2['message']! as types.Message;

          return message1.id == message2.id;
        } else {
          return item1 == item2;
        }
      },
    );

    for (final update in diffResult.getUpdates(batch: false)) {
      update.when(
        insert: (pos, count) {
          _listKey.currentState?.insertItem(pos);
        },
        remove: (pos, count) {
          final item = oldList[pos];
          _listKey.currentState?.removeItem(
            pos,
            (_, animation) => _removedMessageBuilder(item, animation),
          );
        },
        change: (pos, payload) {},
        move: (from, to) {},
      );
    }

    _scrollToBottomIfNeeded(oldList);

    _oldData = List.from(widget.items);
  }

  Widget _removedMessageBuilder(Object item, Animation<double> animation) =>
      SizeTransition(
        axisAlignment: -1,
        sizeFactor: animation.drive(CurveTween(curve: Curves.easeInQuad)),
        child: FadeTransition(
          opacity: animation.drive(CurveTween(curve: Curves.easeInQuad)),
          child: widget.itemBuilder(item, null),
        ),
      );

  // Hacky solution to reconsider.
  void _scrollToBottomIfNeeded(List<Object> oldList) {
    try {
      // Take index 1 because there is always a spacer on index 0.
      final oldItem = oldList[1];
      final item = widget.items[1];

      if (oldItem is Map<String, Object> && item is Map<String, Object>) {
        final oldMessage = oldItem['message']! as types.Message;
        final message = item['message']! as types.Message;

        // Compare items to fire only on newly added messages.
        if (oldMessage != message) {
          // Run only for sent message.
          if (message.author.id == InheritedUser.of(context).user.id) {
            // Delay to give some time for Flutter to calculate new
            // size after new message was added
            Future.delayed(const Duration(milliseconds: 100), () {
              if (_scrollController.hasClients) {
                _scrollController.animateTo(
                  0,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInQuad,
                );
              }
            });
          }
        }
      }
    } catch (e) {
      // Do nothing if there are no items.
    }
  }

  Key? _valueKeyForItem(Object item) {
    if (item is Map<String, Object>) {
      final message = item['message']! as types.Message;
      return ValueKey(message.id);
    } else if (item is MessageSpacer) {
      return ValueKey("spacer ${item.id}");
    } else if (item is DateHeader) {
      return ValueKey(item.dateTime);
    }
    return null;
  }
}

class AnimatedMessage extends StatefulWidget {
  const AnimatedMessage({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  _AnimatedMessageState createState() => _AnimatedMessageState();
}

class _AnimatedMessageState extends State<AnimatedMessage>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );

    _animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInQuad,
    );

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizeTransition(
        axisAlignment: 1,
        sizeFactor: _animation,
        child: widget.child,
      );
}
