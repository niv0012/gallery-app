import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_es.dart';
import 'app_localizations_hi.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale) : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate = _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates = <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('es'),
    Locale('hi')
  ];

  /// The name of the application
  ///
  /// In en, this message translates to:
  /// **'picgallery'**
  String get appName;

  /// Home navigation label
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get home;

  /// Albums label
  ///
  /// In en, this message translates to:
  /// **'Albums'**
  String get albums;

  /// Collections profile and settings menu option
  ///
  /// In en, this message translates to:
  /// **'Collections'**
  String get collections;

  /// Downloads label
  ///
  /// In en, this message translates to:
  /// **'Downloads'**
  String get downloads;

  /// Profile tab and settings title
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get profile;

  /// Settings label
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// Language settings option
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// Save action text
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// Cancel action text
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// Delete action text
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// Search bar label
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get search;

  /// Notifications settings and alerts
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get notifications;

  /// Help and Support settings option
  ///
  /// In en, this message translates to:
  /// **'Help & Support'**
  String get helpSupport;

  /// Privacy Policy settings option
  ///
  /// In en, this message translates to:
  /// **'Privacy Policy'**
  String get privacyPolicy;

  /// Terms and Conditions settings option
  ///
  /// In en, this message translates to:
  /// **'Terms & Conditions'**
  String get termsConditions;

  /// No description provided for @selected.
  ///
  /// In en, this message translates to:
  /// **'Selected'**
  String get selected;

  /// No description provided for @selectLanguage.
  ///
  /// In en, this message translates to:
  /// **'Select Language'**
  String get selectLanguage;

  /// No description provided for @gallery.
  ///
  /// In en, this message translates to:
  /// **'Gallery'**
  String get gallery;

  /// No description provided for @editProfile.
  ///
  /// In en, this message translates to:
  /// **'Edit Profile'**
  String get editProfile;

  /// No description provided for @privacySecurity.
  ///
  /// In en, this message translates to:
  /// **'Privacy & Security'**
  String get privacySecurity;

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @logOut.
  ///
  /// In en, this message translates to:
  /// **'Log Out'**
  String get logOut;

  /// No description provided for @folderExplorerMyFiles.
  ///
  /// In en, this message translates to:
  /// **'My Files'**
  String get folderExplorerMyFiles;

  /// No description provided for @folderExplorerManageFolders.
  ///
  /// In en, this message translates to:
  /// **'Manage Folders'**
  String get folderExplorerManageFolders;

  /// No description provided for @folderExplorerMenu.
  ///
  /// In en, this message translates to:
  /// **'Folder explorer menu'**
  String get folderExplorerMenu;

  /// No description provided for @folderExplorerAllAlbums.
  ///
  /// In en, this message translates to:
  /// **'All Albums'**
  String get folderExplorerAllAlbums;

  /// No description provided for @folderExplorerEmpty.
  ///
  /// In en, this message translates to:
  /// **'This folder is empty.'**
  String get folderExplorerEmpty;

  /// No description provided for @folderExplorerLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading contents…'**
  String get folderExplorerLoading;

  /// No description provided for @folderExplorerGrid.
  ///
  /// In en, this message translates to:
  /// **'Grid'**
  String get folderExplorerGrid;

  /// No description provided for @folderExplorerList.
  ///
  /// In en, this message translates to:
  /// **'List'**
  String get folderExplorerList;

  /// No description provided for @folderExplorerDetails.
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get folderExplorerDetails;

  /// No description provided for @folderExplorerSortByName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get folderExplorerSortByName;

  /// No description provided for @folderExplorerSortByDate.
  ///
  /// In en, this message translates to:
  /// **'Date'**
  String get folderExplorerSortByDate;

  /// No description provided for @folderExplorerSortByDateCreated.
  ///
  /// In en, this message translates to:
  /// **'Date Created'**
  String get folderExplorerSortByDateCreated;

  /// No description provided for @folderExplorerSortBySize.
  ///
  /// In en, this message translates to:
  /// **'Size'**
  String get folderExplorerSortBySize;

  /// No description provided for @folderExplorerAscending.
  ///
  /// In en, this message translates to:
  /// **'Ascending'**
  String get folderExplorerAscending;

  /// No description provided for @folderExplorerDescending.
  ///
  /// In en, this message translates to:
  /// **'Descending'**
  String get folderExplorerDescending;

  /// No description provided for @folderExplorerLooseMedia.
  ///
  /// In en, this message translates to:
  /// **'Loose Media'**
  String get folderExplorerLooseMedia;

  /// No description provided for @folderExplorerFolders.
  ///
  /// In en, this message translates to:
  /// **'Folders'**
  String get folderExplorerFolders;

  /// No description provided for @folderExplorerType.
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get folderExplorerType;

  /// No description provided for @folderExplorerItems.
  ///
  /// In en, this message translates to:
  /// **'Items'**
  String get folderExplorerItems;

  /// No description provided for @uploadCompressLabel.
  ///
  /// In en, this message translates to:
  /// **'Compress files before upload'**
  String get uploadCompressLabel;

  /// No description provided for @uploadCompressSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Photos are resized to 2048 px at JPEG quality 85. Videos are not compressed.'**
  String get uploadCompressSubtitle;
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>['en', 'es', 'hi'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {


  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en': return AppLocalizationsEn();
    case 'es': return AppLocalizationsEs();
    case 'hi': return AppLocalizationsHi();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.'
  );
}
