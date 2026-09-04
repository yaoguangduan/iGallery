import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../../core/upload_manager.dart';
import 'folder_picker.dart';

class ShareHandler extends StatefulWidget {
  final Widget child;
  const ShareHandler({super.key, required this.child});

  @override
  State<ShareHandler> createState() => _ShareHandlerState();
}

class _ShareHandlerState extends State<ShareHandler> {
  StreamSubscription<List<SharedMediaFile>>? _sub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ReceiveSharingIntent.instance.getInitialMedia().then((files) {
        if (files.isNotEmpty && mounted) _handleShared(files);
        ReceiveSharingIntent.instance.reset();
      });
    });
    _sub = ReceiveSharingIntent.instance.getMediaStream().listen((files) {
      if (files.isNotEmpty && mounted) _handleShared(files);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _handleShared(List<SharedMediaFile> shared) {
    final files = shared
        .where((f) => f.path.isNotEmpty)
        .map((f) => PendingUpload(File(f.path)))
        .toList();
    if (files.isEmpty || !mounted) return;
    unawaited(showFolderPickerAndUpload(context, files));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
