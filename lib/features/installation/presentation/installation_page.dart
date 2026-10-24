import 'package:flutter/material.dart';

import '../../../shared/widgets/common.dart';
import 'installation_view.dart';

class InstallationPage extends StatelessWidget {
  const InstallationPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PageBody(
      children: [
        PageHeader(
          title: 'Installation',
          subtitle: 'Where florestad lives on this computer and how to get it.',
        ),
        InstallationView(),
      ],
    );
  }
}
