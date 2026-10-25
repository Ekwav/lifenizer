import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api_client.dart';
import 'app_state.dart';
import 'models.dart';
import 'image_service.dart';
import 'pages/login_page.dart';
import 'pricing_page.dart';
import 'services/quick_action_service.dart';

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
    final colors = Theme.of(context).colorScheme;

    return MaterialBanner(
      backgroundColor: quota.isOverLimit
          ? colors.errorContainer
          : colors.tertiaryContainer,
      contentTextStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: quota.isOverLimit
            ? colors.onErrorContainer
            : colors.onTertiaryContainer,
      ),
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

  Future<void> _upgrade(String plan) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (!widget.state.isAuthenticated) {
        throw StateError('Sign in to upgrade.');
      }
      if (plan == 'premium' &&
          widget.state.quotaStatus?.freePremiumEnabled == true) {
        await widget.state.activateFreePremium();
        return;
      }
      final url = await widget.state.checkoutUrl(plan);
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (mounted) Navigator.of(context).pop();
      } else if (mounted) {
        setState(() => _error = 'Could not open browser. URL: $url');
      }
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _error = 'Could not complete the upgrade. Retry when connected.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _cancelFreePremium() async {
    final quota = widget.state.quotaStatus;
    if (quota?.freePremiumActivatedAt == null ||
        !await confirmFreePremiumCancellation(context, quota!)) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.state.cancelFreePremium();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not cancel the free activation. Check your connection and retry.',
        );
      }
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
        child: SingleChildScrollView(
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
              if (widget.state.isAuthenticated) ...[
                Text(
                  'Account: ${widget.state.rememberedEmail}\nServer: ${widget.state.apiBaseUrl}',
                ),
                const SizedBox(height: 8),
              ],
              if (_error != null) ...[
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: 8),
              ],
              if (!widget.state.isAuthenticated) ...[
                const Text('Sign in to your Lifenizer account to upgrade.'),
                FilledButton(
                  onPressed: () {
                    QuickActionService.instance.request(
                      const QuickAction(action: 'pricing'),
                    );
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => LoginPage(state: widget.state),
                      ),
                    );
                  },
                  child: const Text('Sign in to upgrade'),
                ),
              ] else if (quota?.freePremiumEnabled == true) ...[
                const Text(
                  'Premium is free for now. Activate 10 GB without a payment or card.',
                ),
                if (quota?.plan == 'Free')
                  FilledButton(
                    onPressed: _loading ? null : () => _upgrade('premium'),
                    child: const Text('Activate free Premium'),
                  )
                else
                  const Text('Your storage plan is active.'),
                const SizedBox(height: 8),
                const _PlanCard(
                  title: 'Premium+',
                  price: '€19.99 / month',
                  actionLabel: 'Paid checkout paused',
                  storage: '100 GB',
                  highlighted: true,
                ),
                if (_loading) const LinearProgressIndicator(),
              ] else ...[
                _PlanCard(
                  title: 'Premium',
                  price: '€4.99 / month',
                  storage: '10 GB',
                  onTap: _loading ? null : () => _upgrade('premium'),
                ),
                const SizedBox(height: 8),
                _PlanCard(
                  title: 'Premium+',
                  price: '€19.99 / month',
                  storage: '100 GB',
                  highlighted: true,
                  onTap: _loading ? null : () => _upgrade('premium-plus'),
                ),
              ],
              if (widget.state.isAuthenticated &&
                  quota?.freePremiumActivatedAt != null) ...[
                _PlanCard(
                  title: 'Free',
                  price: '€0',
                  storage: '50 MB',
                  actionLabel: quota?.expiresAt == null
                      ? 'Switch to Free'
                      : 'End free activation',
                  onTap: _loading ? null : _cancelFreePremium,
                ),
                TextButton(
                  onPressed: _loading ? null : _cancelFreePremium,
                  child: Text(freePremiumCancellationLabel(quota!)),
                ),
              ],
            ],
          ),
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
    this.actionLabel = 'Select',
    this.onTap,
  });

  final String title;
  final String price;
  final String storage;
  final bool highlighted;
  final String actionLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: highlighted
          ? Theme.of(context).colorScheme.primaryContainer
          : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('$storage · $price'),
            FilledButton(onPressed: onTap, child: Text(actionLabel)),
          ],
        ),
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
    widget.state
        .refreshImages(conversationId: widget.conversationId)
        .catchError((Object error) {
          if (mounted && widget.state.isAuthenticated) {
            widget.state.reportError('Could not load images: $error');
          }
        });
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
        if (items.any((image) => image.contentType.startsWith('image/')))
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'Older images were uploaded without vault encryption.',
              style: TextStyle(fontSize: 12),
            ),
          ),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'No images yet',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          SizedBox(
            height: 100,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (ctx, i) {
                final img = items[i];
                return GestureDetector(
                  onTap: () => _openFullScreen(context, img),
                  onLongPress: () => _confirmDelete(context, img),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: _DecryptedVaultImage(
                      state: widget.state,
                      image: img,
                      width: 100,
                      height: 100,
                      fit: BoxFit.cover,
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

  Future<void> _confirmDelete(BuildContext dialogContext, ImageItem img) async {
    final confirmed = await showDialog<bool>(
      context: dialogContext,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete image?'),
        content: Text(
          img.contentType.startsWith('image/') ? img.fileName : 'Private image',
        ),
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
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        if (!state.isAuthenticated) {
          return const Scaffold(body: Center(child: Icon(Icons.lock)));
        }
        return Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text(
              image.contentType.startsWith('image/')
                  ? image.fileName
                  : 'Private image',
            ),
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
                    try {
                      await state.deleteImage(image.id);
                      if (context.mounted) Navigator.of(context).pop();
                    } catch (error) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Delete failed: $error')),
                        );
                      }
                    }
                  }
                },
              ),
            ],
          ),
          body: Center(
            child: InteractiveViewer(
              child: _DecryptedVaultImage(
                state: state,
                image: image,
                fit: BoxFit.contain,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Decoded pixels remain in memory and are evicted when locked or disposed.
class _DecryptedVaultImage extends StatefulWidget {
  const _DecryptedVaultImage({
    required this.state,
    required this.image,
    required this.fit,
    this.width,
    this.height,
  });
  final LifenizerAppState state;
  final ImageItem image;
  final BoxFit fit;
  final double? width;
  final double? height;
  @override
  State<_DecryptedVaultImage> createState() => _DecryptedVaultImageState();
}

class _DecryptedVaultImageState extends State<_DecryptedVaultImage> {
  Future<CapturedImage>? _image;
  MemoryImage? _provider;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_vaultChanged);
    _load();
  }

  void _load() {
    _provider?.evict();
    _provider = null;
    _image = widget.state.isAuthenticated
        ? widget.state.decryptedImage(widget.image)
        : null;
  }

  void _vaultChanged() {
    if (!widget.state.isAuthenticated || _image == null) {
      setState(_load);
    }
  }

  @override
  void didUpdateWidget(covariant _DecryptedVaultImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_vaultChanged);
      widget.state.addListener(_vaultChanged);
    }
    if (oldWidget.state != widget.state ||
        oldWidget.image.id != widget.image.id) {
      _load();
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_vaultChanged);
    _provider?.evict();
    _image = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.state.isAuthenticated) return const Icon(Icons.lock);
    return FutureBuilder<CapturedImage>(
      future: _image,
      builder: (context, snapshot) {
        if (snapshot.hasError) return const Icon(Icons.broken_image);
        if (snapshot.connectionState != ConnectionState.done ||
            !snapshot.hasData) {
          return SizedBox(
            width: widget.width,
            height: widget.height,
            child: const Center(child: CircularProgressIndicator()),
          );
        }
        _provider ??= MemoryImage(snapshot.data!.bytes);
        return Image(
          image: _provider!,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          errorBuilder: (_, _, _) => const Icon(Icons.broken_image),
        );
      },
    );
  }
}
