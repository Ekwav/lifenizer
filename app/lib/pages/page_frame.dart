import 'package:flutter/material.dart';

/// Shared page layout: a centered, scrollable column with a title heading.
///
/// Used by every top-level vault page to keep spacing and max-width
/// consistent.
class PageFrame extends StatelessWidget {
  const PageFrame({required this.title, required Widget this.child, super.key})
    : slivers = null;

  const PageFrame.slivers({
    required this.title,
    required List<Widget> this.slivers,
    super.key,
  }) : child = null;

  final String title;
  final Widget? child;
  final List<Widget>? slivers;

  @override
  Widget build(BuildContext context) {
    if (slivers != null) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final horizontal = constraints.maxWidth > 1160
              ? (constraints.maxWidth - 1120) / 2
              : 20.0;
          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(horizontal, 16, horizontal, 80),
                sliver: SliverMainAxisGroup(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Text(
                          title,
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                      ),
                    ),
                    ...slivers!,
                  ],
                ),
              ),
            ],
          );
        },
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 80),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 16),
              child!,
            ],
          ),
        ),
      ),
    );
  }
}
