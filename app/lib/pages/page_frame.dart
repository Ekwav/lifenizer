import 'package:flutter/material.dart';

/// Shared page layout: a centered, scrollable column with a title heading.
///
/// Used by every top-level vault page to keep spacing and max-width
/// consistent.
class PageFrame extends StatelessWidget {
  const PageFrame({required this.title, required this.child, super.key});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
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
              child,
            ],
          ),
        ),
      ),
    );
  }
}
