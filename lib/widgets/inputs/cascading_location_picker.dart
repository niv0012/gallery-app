import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/constants/app_constants.dart';
import '../../providers/location_providers.dart';
import '../../core/theme/theme_context.dart';

/// Country → State → City cascading picker used on the Complete Profile
/// and Edit Profile screens.
///
/// Every level is fetched live from the backend's `/locations/*`
/// endpoints (`LocationRepository` → `app/api/routes/locations.py`),
/// which serve the full offline country/state/city dataset (250
/// countries, ~5k states/provinces, ~148k cities — see
/// `app/core/location_data.py`). This used to be a hardcoded
/// client-side map covering only a handful of cities per state (e.g.
/// 6 for all of Gujarat) — that's what caused "only some cities show
/// up". Now both sides agree: whatever the picker shows is exactly
/// what the backend recognizes as valid for that country/state, so a
/// value saved here always round-trips correctly.
///
/// Each field opens its own full-height, searchable bottom sheet
/// ([_LocationSearchSheet]) instead of an inline Material dropdown, so
/// a long list is never clipped down to just a couple of visible rows.
///
/// If a fetch fails (offline, backend unreachable) or the backend has
/// no state/city list for a given selection, the field disables itself
/// and a free-text fallback appears below it — so nothing is ever
/// blocked by a network hiccup or a gap in the dataset.
class CascadingLocationPicker extends ConsumerStatefulWidget {
  final String? initialCountry;
  final String? initialState;
  final String? initialCity;

  /// Fired on every change with the current (country, state, city) triple.
  final void Function(String? country, String? state, String? city) onChanged;

  const CascadingLocationPicker({
    super.key,
    this.initialCountry,
    this.initialState,
    this.initialCity,
    required this.onChanged,
  });

  @override
  ConsumerState<CascadingLocationPicker> createState() =>
      _CascadingLocationPickerState();
}

class _CascadingLocationPickerState
    extends ConsumerState<CascadingLocationPicker> {
  String? _country;
  String? _state;
  String? _city;

  late final TextEditingController _stateFallbackController;
  late final TextEditingController _cityFallbackController;

  // `null` countries list = not fetched yet; `_kAllCountries` is only
  // ever used as an offline fallback if the fetch itself fails.
  List<String>? _countries;
  bool _countriesLoading = false;

  List<String> _states = [];
  bool _statesLoading = false;

  List<String> _cities = [];
  bool _citiesLoading = false;

  @override
  void initState() {
    super.initState();
    _country = widget.initialCountry;
    _state = widget.initialState;
    _city = widget.initialCity;
    _stateFallbackController = TextEditingController();
    _cityFallbackController = TextEditingController();
    _bootstrap();
  }

  @override
  void dispose() {
    _stateFallbackController.dispose();
    _cityFallbackController.dispose();
    super.dispose();
  }

  /// Loads countries, then — if this profile already has a
  /// country/state saved (edit flow) — loads states and cities too, so
  /// the previously-saved value can be checked against the *current*
  /// backend dataset. If it's no longer recognized, it's moved into the
  /// free-text fallback rather than silently shown as if still valid.
  Future<void> _bootstrap() async {
    await _fetchCountries();
    if (_country != null) {
      await _fetchStates(revalidate: true);
      if (_state != null) {
        await _fetchCities(revalidate: true);
      }
    }
  }

  Future<void> _fetchCountries() async {
    setState(() => _countriesLoading = true);
    try {
      final list = await ref.read(locationRepositoryProvider).fetchCountries();
      if (!mounted) return;
      setState(() {
        _countries = list;
        _countriesLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _countries = _kAllCountries;
        _countriesLoading = false;
      });
    }
  }

  Future<void> _fetchStates({bool revalidate = false}) async {
    final country = _country;
    if (country == null) {
      setState(() => _states = []);
      return;
    }
    setState(() => _statesLoading = true);
    try {
      final list =
          await ref.read(locationRepositoryProvider).fetchStates(country);
      if (!mounted || _country != country) return;
      setState(() {
        _states = list;
        _statesLoading = false;
        if (revalidate && _state != null && !list.contains(_state)) {
          _stateFallbackController.text = _state!;
          _state = null;
        }
      });
    } catch (_) {
      if (!mounted || _country != country) return;
      setState(() {
        _states = [];
        _statesLoading = false;
      });
    }
  }

  Future<void> _fetchCities({bool revalidate = false}) async {
    final country = _country;
    final state = _state;
    if (country == null || state == null) {
      setState(() => _cities = []);
      return;
    }
    setState(() => _citiesLoading = true);
    try {
      final list = await ref
          .read(locationRepositoryProvider)
          .fetchCities(country, state);
      if (!mounted || _country != country || _state != state) return;
      setState(() {
        _cities = list;
        _citiesLoading = false;
        if (revalidate && _city != null && !list.contains(_city)) {
          _cityFallbackController.text = _city!;
          _city = null;
        }
      });
    } catch (_) {
      if (!mounted || _country != country || _state != state) return;
      setState(() {
        _cities = [];
        _citiesLoading = false;
      });
    }
  }

  void _emit() {
    final state = _state ?? _emptyToNull(_stateFallbackController.text);
    final city = _city ?? _emptyToNull(_cityFallbackController.text);
    widget.onChanged(_country, state, city);
  }

  String? _emptyToNull(String v) => v.trim().isEmpty ? null : v.trim();

  Future<void> _pickCountry() async {
    if (_countriesLoading) return;
    final options = _countries ?? _kAllCountries;
    final picked = await _LocationSearchSheet.show(
      context,
      title: 'Select country',
      options: options,
      current: _country,
    );
    if (picked == null || picked == _country) return;
    setState(() {
      _country = picked;
      _state = null;
      _city = null;
      _states = [];
      _cities = [];
      _stateFallbackController.clear();
      _cityFallbackController.clear();
    });
    _emit();
    _fetchStates();
  }

  Future<void> _pickState() async {
    if (_country == null || _statesLoading || _states.isEmpty) return;
    final picked = await _LocationSearchSheet.show(
      context,
      title: 'Select state / province',
      options: _states,
      current: _state,
    );
    if (picked == null || picked == _state) return;
    setState(() {
      _state = picked;
      _city = null;
      _cities = [];
      _stateFallbackController.clear();
      _cityFallbackController.clear();
    });
    _emit();
    _fetchCities();
  }

  Future<void> _pickCity() async {
    if (_state == null || _citiesLoading || _cities.isEmpty) return;
    final picked = await _LocationSearchSheet.show(
      context,
      title: 'Select city',
      options: _cities,
      current: _city,
    );
    if (picked == null || picked == _city) return;
    setState(() {
      _city = picked;
      _cityFallbackController.clear();
    });
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final stateEnabled =
        _country != null && !_statesLoading && _states.isNotEmpty;
    final stateShowFallback =
        _country != null && !_statesLoading && _states.isEmpty;
    final cityEnabled = _state != null && !_citiesLoading && _cities.isNotEmpty;
    final cityShowFallback =
        _state != null && !_citiesLoading && _cities.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PickerField(
          label: 'Country',
          value: _country,
          hint: _countriesLoading ? 'Loading countries…' : 'Select country',
          icon: Icons.public_rounded,
          loading: _countriesLoading,
          onTap: _pickCountry,
        ),
        const SizedBox(height: AppSpacing.md),
        _PickerField(
          label: 'State / Province',
          value: _state,
          hint: _country == null
              ? 'Select country first'
              : _statesLoading
                  ? 'Loading states…'
                  : _states.isEmpty
                      ? 'No list for this country — type below'
                      : 'Select state',
          icon: Icons.map_outlined,
          enabled: stateEnabled,
          loading: _statesLoading,
          onTap: _pickState,
        ),
        if (stateShowFallback) ...[
          const SizedBox(height: AppSpacing.sm),
          TextFormField(
            controller: _stateFallbackController,
            decoration: InputDecoration(
              labelText: 'State / Province (type it)',
              prefixIcon: Icon(Icons.edit_location_alt_outlined,
                  color: context.textMuted, size: 20),
            ),
            onChanged: (_) => _emit(),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        _PickerField(
          label: 'City',
          value: _city,
          hint: _state == null
              ? 'Select state first'
              : _citiesLoading
                  ? 'Loading cities…'
                  : _cities.isEmpty
                      ? 'No list for this state — type below'
                      : 'Select city',
          icon: Icons.location_city_rounded,
          enabled: cityEnabled,
          loading: _citiesLoading,
          onTap: _pickCity,
        ),
        if (cityShowFallback) ...[
          const SizedBox(height: AppSpacing.sm),
          TextFormField(
            controller: _cityFallbackController,
            decoration: InputDecoration(
              labelText: 'City (type it)',
              prefixIcon: Icon(Icons.edit_location_alt_outlined,
                  color: context.textMuted, size: 20),
            ),
            onChanged: (_) => _emit(),
          ),
        ],
      ],
    );
  }
}

/// Read-only-looking tap target styled like a [DropdownButtonFormField]
/// (same label/icon/border conventions as the rest of the app's inputs)
/// that opens [_LocationSearchSheet] instead of an inline dropdown.
class _PickerField extends StatelessWidget {
  final String label;
  final String? value;
  final String hint;
  final IconData icon;
  final bool enabled;
  final bool loading;
  final VoidCallback onTap;

  const _PickerField({
    required this.label,
    required this.value,
    required this.hint,
    required this.icon,
    required this.onTap,
    this.enabled = true,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? AppColors.textOnDark : AppColors.text;
    final subtitleColor =
        isDark ? AppColors.subtitleOnDark : AppColors.subtitle;
    final disabledColor = isDark ? AppColors.darkBorder : AppColors.border;

    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon,
            color: enabled ? AppColors.primary : subtitleColor, size: 20),
        enabled: enabled || loading,
      ),
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                value ?? hint,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14.5,
                  color: value == null ? subtitleColor : textColor,
                ),
              ),
            ),
            if (loading)
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: subtitleColor),
              )
            else
              Icon(Icons.arrow_drop_down_rounded,
                  color: enabled ? subtitleColor : disabledColor),
          ],
        ),
      ),
    );
  }
}

/// Full-height, searchable picker sheet. Always renders its list in a
/// bounded [SizedBox] + [ListView.builder], so no matter how long
/// [options] is, the whole list is reachable by scrolling — this is the
/// piece that guarantees "more than 1-2 items show up".
class _LocationSearchSheet extends StatefulWidget {
  final String title;
  final List<String> options;
  final String? current;

  const _LocationSearchSheet(
      {required this.title, required this.options, required this.current});

  static Future<String?> show(
    BuildContext context, {
    required String title,
    required List<String> options,
    required String? current,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? AppColors.darkSurface : AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _LocationSearchSheet(
          title: title, options: options, current: current),
    );
  }

  @override
  State<_LocationSearchSheet> createState() => _LocationSearchSheetState();
}

class _LocationSearchSheetState extends State<_LocationSearchSheet> {
  late List<String> _filtered;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _filtered = widget.options;
  }

  void _onSearch(String query) {
    setState(() {
      _filtered = query.trim().isEmpty
          ? widget.options
          : widget.options
              .where(
                  (o) => o.toLowerCase().contains(query.trim().toLowerCase()))
              .toList();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Fixed proportion of the screen so the sheet — and therefore the
    // list inside it — always has real, generous height to scroll in,
    // regardless of how many options there are.
    final sheetHeight = MediaQuery.of(context).size.height * 0.75;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? AppColors.textOnDark : AppColors.text;
    final subtitleColor =
        isDark ? AppColors.subtitleOnDark : AppColors.subtitle;
    final handleColor = isDark ? AppColors.darkBorder : AppColors.border;

    return SafeArea(
      child: SizedBox(
        height: sheetHeight,
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: handleColor,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(widget.title,
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: textColor)),
                  Text('${_filtered.length} of ${widget.options.length}',
                      style: TextStyle(fontSize: 12.5, color: subtitleColor)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: TextField(
                controller: _searchController,
                autofocus: false,
                onChanged: _onSearch,
                style: TextStyle(color: textColor),
                decoration: InputDecoration(
                  hintText: 'Search…',
                  prefixIcon: Icon(Icons.search_rounded,
                      color: subtitleColor, size: 20),
                ),
              ),
            ),
            Expanded(
              child: _filtered.isEmpty
                  ? Center(
                      child: Text('No matches',
                          style: TextStyle(color: subtitleColor)))
                  : ListView.builder(
                      // Always a real scrollable list — every filtered
                      // entry is laid out and reachable, never capped.
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: _filtered.length,
                      itemBuilder: (context, index) {
                        final option = _filtered[index];
                        final selected = option == widget.current;
                        return ListTile(
                          title: Text(option,
                              style: TextStyle(
                                  color:
                                      selected ? AppColors.primary : textColor,
                                  fontWeight: selected
                                      ? FontWeight.bold
                                      : FontWeight.normal)),
                          trailing: selected
                              ? const Icon(Icons.check_rounded,
                                  color: AppColors.primary, size: 18)
                              : null,
                          onTap: () => Navigator.of(context).pop(option),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Offline fallback for the Country field ONLY, used if the
/// `/locations/countries` fetch itself fails (e.g. no network). States
/// and cities always come from the backend — there is no equivalent
/// hardcoded fallback for those, since a partial/stale local copy is
/// exactly what caused the original "only some cities" bug. If the
/// backend is unreachable when a state/state+city is needed, the field
/// disables and the free-text fallback below it takes over instead.
const List<String> _kAllCountries = [
  'Afghanistan',
  'Albania',
  'Algeria',
  'Andorra',
  'Angola',
  'Antigua and Barbuda',
  'Argentina',
  'Armenia',
  'Australia',
  'Austria',
  'Azerbaijan',
  'Bahamas',
  'Bahrain',
  'Bangladesh',
  'Barbados',
  'Belarus',
  'Belgium',
  'Belize',
  'Benin',
  'Bhutan',
  'Bolivia',
  'Bosnia and Herzegovina',
  'Botswana',
  'Brazil',
  'Brunei',
  'Bulgaria',
  'Burkina Faso',
  'Burundi',
  'Cabo Verde',
  'Cambodia',
  'Cameroon',
  'Canada',
  'Central African Republic',
  'Chad',
  'Chile',
  'China',
  'Colombia',
  'Comoros',
  'Congo (Congo-Brazzaville)',
  'Costa Rica',
  'Croatia',
  'Cuba',
  'Cyprus',
  'Czechia',
  'Democratic Republic of the Congo',
  'Denmark',
  'Djibouti',
  'Dominica',
  'Dominican Republic',
  'Ecuador',
  'Egypt',
  'El Salvador',
  'Equatorial Guinea',
  'Eritrea',
  'Estonia',
  'Eswatini',
  'Ethiopia',
  'Fiji',
  'Finland',
  'France',
  'Gabon',
  'Gambia',
  'Georgia',
  'Germany',
  'Ghana',
  'Greece',
  'Grenada',
  'Guatemala',
  'Guinea',
  'Guinea-Bissau',
  'Guyana',
  'Haiti',
  'Honduras',
  'Hungary',
  'Iceland',
  'India',
  'Indonesia',
  'Iran',
  'Iraq',
  'Ireland',
  'Israel',
  'Italy',
  'Jamaica',
  'Japan',
  'Jordan',
  'Kazakhstan',
  'Kenya',
  'Kiribati',
  'Kosovo',
  'Kuwait',
  'Kyrgyzstan',
  'Laos',
  'Latvia',
  'Lebanon',
  'Lesotho',
  'Liberia',
  'Libya',
  'Liechtenstein',
  'Lithuania',
  'Luxembourg',
  'Madagascar',
  'Malawi',
  'Malaysia',
  'Maldives',
  'Mali',
  'Malta',
  'Marshall Islands',
  'Mauritania',
  'Mauritius',
  'Mexico',
  'Micronesia',
  'Moldova',
  'Monaco',
  'Mongolia',
  'Montenegro',
  'Morocco',
  'Mozambique',
  'Myanmar',
  'Namibia',
  'Nauru',
  'Nepal',
  'Netherlands',
  'New Zealand',
  'Nicaragua',
  'Niger',
  'Nigeria',
  'North Korea',
  'North Macedonia',
  'Norway',
  'Oman',
  'Pakistan',
  'Palau',
  'Palestine',
  'Panama',
  'Papua New Guinea',
  'Paraguay',
  'Peru',
  'Philippines',
  'Poland',
  'Portugal',
  'Qatar',
  'Romania',
  'Russia',
  'Rwanda',
  'Saint Kitts and Nevis',
  'Saint Lucia',
  'Saint Vincent and the Grenadines',
  'Samoa',
  'San Marino',
  'Sao Tome and Principe',
  'Saudi Arabia',
  'Senegal',
  'Serbia',
  'Seychelles',
  'Sierra Leone',
  'Singapore',
  'Slovakia',
  'Slovenia',
  'Solomon Islands',
  'Somalia',
  'South Africa',
  'South Korea',
  'South Sudan',
  'Spain',
  'Sri Lanka',
  'Sudan',
  'Suriname',
  'Sweden',
  'Switzerland',
  'Syria',
  'Taiwan',
  'Tajikistan',
  'Tanzania',
  'Thailand',
  'Timor-Leste',
  'Togo',
  'Tonga',
  'Trinidad and Tobago',
  'Tunisia',
  'Turkey',
  'Turkmenistan',
  'Tuvalu',
  'Uganda',
  'Ukraine',
  'United Arab Emirates',
  'United Kingdom',
  'United States',
  'Uruguay',
  'Uzbekistan',
  'Vanuatu',
  'Vatican City',
  'Venezuela',
  'Vietnam',
  'Yemen',
  'Zambia',
  'Zimbabwe',
];
