import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api_client.dart';
import 'app_state.dart';
import 'models.dart';

// ============================================================================
//  StorageQuotaBanner
//  Shows a sticky warning if usage ≥ 80 % of quota.
// ============================================================================

class StorageQuotaBanner extends StatelessWidget {
  const StorageQuotaBanner({required this.state, super.key});

  final LifenizerAppState state;

  @override
  Widget build(BuildContext context) {
    final quota = state.quotaStatus;
    if (quota == null || !quota.isNearLimit) return const SizedBox.shrink();

    return MaterialBanner(
      backgroundColor: quota.isOverLimit
          ? Theme.of(context).colorScheme.errorContainer
          : Colors.amber.shade100,
      content: Text(
        quota.isOverLimit
            ? 'Storage full (${quota.usedFormatted} / ${quota.limitFormatted}). '
                  'Uploads are blocked. Upgrade to continue.'
            : 'Storage at ${quota.usedPercent.toStringAsFixed(0)}% '
                  '(${quota.usedFormatted} / ${quota.limitFormatted}).',
      ),
      actions: [
        TextButton(
          onPressed: () => _showUpgradeDialog(context, state),
          child: const Text('UPGRADE'),
        ),
      ],
    );
  }
}

// ============================================================================
//  UpgradeDialog
// ============================================================================

Future<void> _showUpgradeDialog(BuildContext context, LifenizerAppState state) {
  return showDialog(
    context: context,
    builder: (ctx) => UpgradeDialog(state: state),
  );
}

class UpgradeDialog extends StatefulWidget {
  const UpgradeDialog({required this.state, super.key});

  final LifenizerAppState state;

  @override
  State<UpgradeDialog> createState() => _UpgradeDialogState();
}

class _UpgradeDialogState extends State<UpgradeDialog> {
  bool _loading = false;
  String? _error;

  Future<void> _checkout(String plan) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final url = await widget.state.checkoutUrl(plan);
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (mounted) Navigator.of(context).pop();
      } else {
        setState(() => _error = 'Could not open browser. URL: $url');
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final quota = widget.state.quotaStatus;
    return AlertDialog(
      title: const Text('Upgrade storage'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (quota != null) ...[
              Text(
                'Current plan: ${quota.plan}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              LinearProgressIndicator(
                value: (quota.usedPercent / 100).clamp(0.0, 1.0),
              ),
              Text(
                '${quota.usedFormatted} of ${quota.limitFormatted} used',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
            ],
            if (_error != null) ...[
              Text(_error!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 8),
            ],
            _PlanCard(
              title: 'Premium',
              price: '€4.99 / month',
              storage: '10 GB',
              onTap: _loading ? null : () => _checkout('premium'),
            ),
            const SizedBox(height: 8),
            _PlanCard(
              title: 'Premium+',
              price: '€19.99 / month',
              storage: '100 GB',
              highlighted: true,
              onTap: _loading ? null : () => _checkout('premium-plus'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.title,
    required this.price,
    required this.storage,
    this.highlighted = false,
    this.onTap,
  });

  final String title;
  final String price;
  final String storage;
  final bool highlighted;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: highlighted
          ? Theme.of(context).colorScheme.primaryContainer
          : null,
      child: ListTile(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text('$storage · $price'),
        trailing: FilledButton(onPressed: onTap, child: const Text('Select')),
      ),
    );
  }
}

// ============================================================================
//  ImageGallery  –  shows images for a conversation and an "add" button
// ============================================================================

class ImageGallery extends StatefulWidget {
  const ImageGallery({
    required this.state,
    required this.conversationId,
    super.key,
  });

  final LifenizerAppState state;
  final String conversationId;

  @override
  State<ImageGallery> createState() => _ImageGalleryState();
}

class _ImageGalleryState extends State<ImageGallery> {
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    widget.state.refreshImages(conversationId: widget.conversationId);
  }

  List<ImageItem> get _items => widget.state.images
      .where((img) => img.conversationId == widget.conversationId)
      .toList();

  Future<void> _showPickerSheet() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    await _pick(source);
  }

  Future<void> _pick(ImageSource source) async {
    setState(() => _uploading = true);
    try {
      await widget.state.captureAndUploadImage(
        source: source,
        conversationId: widget.conversationId,
      );
    } on QuotaExceededException {
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => UpgradeDialog(state: widget.state),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Images (${items.length})',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const Spacer(),
            if (_uploading)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            IconButton.filled(
              icon: const Icon(Icons.add_a_photo),
              tooltip: 'Add image',
              onPressed: _uploading ? null : _showPickerSheet,
            ),
          ],
        ),
        if (items.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('No images yet', style: TextStyle(color: Colors.grey)),
          )
        else
          SizedBox(
            height: 100,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (ctx, i) {
                final img = items[i];
                return GestureDetector(
                  onTap: () => _openFullScreen(context, img),
                  onLongPress: () => _confirmDelete(context, img),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImage(
                      imageUrl: widget.state.imageUrl(img.id),
                      httpHeaders: widget.state.authHeaders,
                      width: 100,
                      height: 100,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(
                        color: Colors.grey.shade200,
                        width: 100,
                        height: 100,
                        child: const Icon(Icons.image),
                      ),
                      errorWidget: (_, __, ___) => Container(
                        color: Colors.grey.shade200,
                        width: 100,
                        height: 100,
                        child: const Icon(Icons.broken_image),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  void _openFullScreen(BuildContext context, ImageItem img) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _FullScreenImage(state: widget.state, image: img),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, ImageItem img) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete image?'),
        content: Text(img.fileName),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      final messenger = ScaffoldMessenger.of(context);
      try {
        await widget.state.deleteImage(img.id);
      } catch (e) {
        if (mounted) {
          messenger.showSnackBar(SnackBar(content: Text('Delete failed: $e')));
        }
      }
    }
  }
}

// ============================================================================
//  Full-screen image viewer
// ============================================================================

class _FullScreenImage extends StatelessWidget {
  const _FullScreenImage({required this.state, required this.image});

  final LifenizerAppState state;
  final ImageItem image;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(image.fileName),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Delete image?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                await state.deleteImage(image.id);
                if (context.mounted) Navigator.of(context).pop();
              }
            },
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          child: CachedNetworkImage(
            imageUrl: state.imageUrl(image.id),
            httpHeaders: state.authHeaders,
            fit: BoxFit.contain,
            placeholder: (_, __) =>
                const CircularProgressIndicator(color: Colors.white),
            errorWidget: (_, __, ___) =>
                const Icon(Icons.broken_image, color: Colors.white, size: 64),
          ),
        ),
      ),
    );
  }
}
