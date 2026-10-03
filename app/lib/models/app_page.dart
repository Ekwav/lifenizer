import 'package:flutter/material.dart';

/// Enum representing all pages in the Lifenizer vault shell application.
///
/// Each page has an associated icon and label for use in navigation UI.
enum AppPage {
  search(Icons.search, 'Search'),
  insights(Icons.insights_outlined, 'Insights'),
  capture(Icons.add_circle_outline, 'Capture'),
  imports(Icons.input, 'Imports'),
  participants(Icons.people_outline, 'People'),
  relations(Icons.account_tree_outlined, 'Relations'),
  sync(Icons.sync, 'Sync'),
  pricing(Icons.workspace_premium_outlined, 'Plans');

  const AppPage(this.icon, this.label);

  /// Icon to display in navigation rail and bottom navigation bar.
  final IconData icon;

  /// Label to display in navigation UI.
  final String label;
}

/// Extension on [AppPage] enum to provide navigation item builders.
///
/// This extension provides unified navigation item generation for both
/// wide (NavigationRail) and narrow (NavigationBar) layouts.
extension AppPageNavigation on AppPage {
  /// Builds a [NavigationRailDestination] for this app page.
  ///
  /// Used in wide layouts with the navigation rail.
  NavigationRailDestination get railDestination {
    return NavigationRailDestination(icon: Icon(icon), label: Text(label));
  }

  /// Builds a [NavigationDestination] for this app page.
  ///
  /// Used in narrow layouts with the bottom navigation bar.
  NavigationDestination get navDestination {
    return NavigationDestination(icon: Icon(icon), label: label);
  }
}
