import 'package:flutter/material.dart';

import '../shared/gallery_view.dart';

class MobileShell extends StatelessWidget {
  const MobileShell({super.key});

  @override
  Widget build(BuildContext context) {
    return const SafeArea(child: GalleryView());
  }
}
