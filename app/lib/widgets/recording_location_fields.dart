import 'package:flutter/material.dart';

import '../models.dart';
import '../services/recording_location_service.dart';

/// Town comes first because it is usually the remembered part of a place.
class RecordingLocationFields extends StatefulWidget {
  const RecordingLocationFields({
    this.location,
    required this.onChanged,
    this.enabled = true,
    super.key,
  });
  final RecordingLocation? location;
  final ValueChanged<RecordingLocation?> onChanged;
  final bool enabled;

  @override
  State<RecordingLocationFields> createState() =>
      _RecordingLocationFieldsState();
}

class _RecordingLocationFieldsState extends State<RecordingLocationFields> {
  late RecordingLocation? _location = widget.location;
  late final _town = TextEditingController(text: _location?.town);
  late final _venue = TextEditingController(text: _location?.venue);
  late final _address = TextEditingController(text: _location?.address);
  bool _finding = false;
  String? _error;

  void _changed([String? _]) {
    _location = RecordingLocation(
      town: _town.text,
      venue: _venue.text,
      address: _address.text,
      latitude: _location?.latitude,
      longitude: _location?.longitude,
    );
    widget.onChanged(_location!.toJson().isEmpty ? null : _location);
  }

  Future<void> _current() async {
    setState(() {
      _finding = true;
      _error = null;
    });
    final service = RecordingLocationService.instance;
    final permitted = await service.requestPermission();
    final location = permitted ? await service.getCurrentLocation() : null;
    if (!mounted) return;
    setState(() {
      _finding = false;
      if (location == null) {
        _error =
            'Location unavailable. Enter the town and venue manually, or retry.';
      } else {
        _location = location;
        _town.text = location.town;
        _venue.text = location.venue;
        _address.text = location.address;
        _changed();
      }
    });
  }

  @override
  void dispose() {
    _town.dispose();
    _venue.dispose();
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        controller: _town,
        enabled: widget.enabled && !_finding,
        onChanged: _changed,
        decoration: const InputDecoration(
          labelText: 'Town or city',
          prefixIcon: Icon(Icons.location_city),
        ),
      ),
      TextField(
        controller: _venue,
        enabled: widget.enabled && !_finding,
        onChanged: _changed,
        decoration: const InputDecoration(
          labelText: 'Venue',
          hintText: 'Café, office, event…',
        ),
      ),
      TextField(
        controller: _address,
        enabled: widget.enabled && !_finding,
        onChanged: _changed,
        decoration: const InputDecoration(labelText: 'Address (optional)'),
      ),
      Wrap(
        spacing: 8,
        children: [
          if (RecordingLocationService.instance.supported)
            TextButton.icon(
              onPressed: widget.enabled && !_finding ? _current : null,
              icon: const Icon(Icons.my_location),
              label: Text(
                _finding ? 'Finding location…' : 'Use current location',
              ),
            ),
          TextButton(
            onPressed: widget.enabled && !_finding
                ? () {
                    setState(() {
                      _location = null;
                      _town.clear();
                      _venue.clear();
                      _address.clear();
                      _error = null;
                    });
                    widget.onChanged(null);
                  }
                : null,
            child: const Text('Remove location'),
          ),
        ],
      ),
      if (_error != null)
        Text(
          _error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
    ],
  );
}
