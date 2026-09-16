import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Same policy text as the sister apps (e.g. fuji), adapted to this app's
/// name. Ads (AdMob) run on iOS/Android only — see [isAdsSupportedPlatform]
/// in ad_banner.dart — so the "macOS doesn't serve ads" note still applies.
class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  static const _googlePrivacyUrl = 'https://policies.google.com/privacy';
  static const _contactEmail = 'info@e-onlineservice.com';

  Future<void> _openGooglePrivacy() async {
    final uri = Uri.parse(_googlePrivacyUrl);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _openContactEmail() async {
    final uri = Uri(scheme: 'mailto', path: _contactEmail);
    await launchUrl(uri);
  }

  @override
  Widget build(BuildContext context) {
    final headingStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.bold,
    );
    const bodyStyle = TextStyle(fontSize: 15, height: 1.5);

    return Scaffold(
      appBar: AppBar(title: const Text('Privacy Policy')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('Handling of Personal Information', style: headingStyle),
            const SizedBox(height: 8),
            const Text(
              'This application does not directly collect or store personal '
              'information such as your name, email address, or contact '
              'details.',
              style: bodyStyle,
            ),
            const SizedBox(height: 20),
            Text('Advertising Services and Data Collection (*Mobile Versions Only)', style: headingStyle),
            const SizedBox(height: 8),
            const Text(
              'The iOS and Android versions of this application use AdMob '
              '(Google LLC) as an ad delivery tool. (*The macOS version does '
              'not deliver ads or collect data via AdMob.)',
              style: bodyStyle,
            ),
            const SizedBox(height: 12),
            const Text(
              'AdMob may automatically collect and use the following '
              'information for purposes such as delivering personalized ads, '
              'measuring ad effectiveness, and improving services:',
              style: bodyStyle,
            ),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('• Device identifiers (e.g., Advertising ID / IDFA / GAID)', style: bodyStyle),
                  Text('• IP address and coarse location data', style: bodyStyle),
                  Text('• App usage data and crash diagnostic data', style: bodyStyle),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text('Tracking and Ad Restrictions', style: headingStyle),
            const SizedBox(height: 8),
            const Text(
              'Users can opt out of or restrict tracking for personalized ads '
              'at any time by changing their device settings (e.g., iOS: '
              '"Allow Apps to Request to Track", Android: "Delete or Reset '
              'Advertising ID").',
              style: bodyStyle,
            ),
            const SizedBox(height: 12),
            const Text(
              "For more details on data collection and use by AdMob, please "
              "refer to Google's Privacy Policy:",
              style: bodyStyle,
            ),
            const SizedBox(height: 4),
            InkWell(
              onTap: _openGooglePrivacy,
              child: Text(
                _googlePrivacyUrl,
                style: TextStyle(
                  fontSize: 15,
                  color: Theme.of(context).colorScheme.primary,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text('Contact Us', style: headingStyle),
            const SizedBox(height: 8),
            const Text(
              'If you have any questions regarding this policy, please '
              'contact us at:',
              style: bodyStyle,
            ),
            const SizedBox(height: 4),
            InkWell(
              onTap: _openContactEmail,
              child: Text(
                _contactEmail,
                style: TextStyle(
                  fontSize: 15,
                  color: Theme.of(context).colorScheme.primary,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
