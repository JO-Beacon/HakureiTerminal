import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/app_settings.dart';
import '../repositories/chat_repository.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.initialSettings,
    this.onCheckDependencies,
    this.onInstallDependencies,
  });

  final AppSettings initialSettings;
  final Future<DependencyStatusResult> Function(AppSettings settings)? onCheckDependencies;
  final Future<DependencyInstallResult> Function(AppSettings settings)? onInstallDependencies;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _providers = <String>[
    'ollama',
    'openai',
    'deepseek',
    'openai_responses',
    'claude',
    'gemini',
  ];

  _SettingsPage _selectedPage = _SettingsPage.modelProvider;

  late AppSettings _settings;
  late ModelProfile _editingProfile;
  late DependencyInstallPolicy _dependencyInstallPolicy;

  late final TextEditingController _profileNameController;
  late final TextEditingController _modelController;
  late final TextEditingController _baseUrlController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _temperatureController;
  late final TextEditingController _topPController;
  late final TextEditingController _maxTokensController;
  late final TextEditingController _timeoutController;
  late final TextEditingController _reasoningEffortController;
  late final TextEditingController _embeddingModelController;
  late final TextEditingController _embeddingBaseUrlController;
  late final TextEditingController _embeddingApiKeyController;
  late final TextEditingController _embeddingDimensionsController;
  late final TextEditingController _embeddingTimeoutController;

  late String _provider;
  late String _embeddingProvider;
  late bool _stream;
  late bool _think;
  late bool _useProxy;
  late bool _embeddingUseProxy;
  bool _obscureApiKey = true;
  bool _obscureEmbeddingApiKey = true;
  bool _checkingDependencies = false;

  @override
  void initState() {
    super.initState();
    _settings = widget.initialSettings;
    _dependencyInstallPolicy = _settings.dependencyInstallPolicy;
    _editingProfile = _settings.activeProfile;
    _profileNameController = TextEditingController();
    _modelController = TextEditingController();
    _baseUrlController = TextEditingController();
    _apiKeyController = TextEditingController();
    _temperatureController = TextEditingController();
    _topPController = TextEditingController();
    _maxTokensController = TextEditingController();
    _timeoutController = TextEditingController();
    _reasoningEffortController = TextEditingController();
    _embeddingModelController = TextEditingController();
    _embeddingBaseUrlController = TextEditingController();
    _embeddingApiKeyController = TextEditingController();
    _embeddingDimensionsController = TextEditingController();
    _embeddingTimeoutController = TextEditingController();
    _loadProfileIntoForm(_editingProfile);
  }

  @override
  void dispose() {
    _profileNameController.dispose();
    _modelController.dispose();
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _temperatureController.dispose();
    _topPController.dispose();
    _maxTokensController.dispose();
    _timeoutController.dispose();
    _reasoningEffortController.dispose();
    _embeddingModelController.dispose();
    _embeddingBaseUrlController.dispose();
    _embeddingApiKeyController.dispose();
    _embeddingDimensionsController.dispose();
    _embeddingTimeoutController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isModelProviderPage = _selectedPage == _SettingsPage.modelProvider;
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: <Widget>[
          if (isModelProviderPage) ...<Widget>[
            TextButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: const Text('保存并生效'),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildSettingsList(),
          const VerticalDivider(width: 1),
          Expanded(child: _buildSelectedPage()),
        ],
      ),
    );
  }

  Widget _buildSettingsList() {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        width: 260,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: <Widget>[
            _buildSettingsListTile(
              page: _SettingsPage.modelProvider,
              icon: Icons.smart_toy_outlined,
              title: '模型服务商',
            ),
            _buildSettingsListTile(
              page: _SettingsPage.about,
              icon: Icons.info_outline,
              title: '关于',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsListTile({
    required _SettingsPage page,
    required IconData icon,
    required String title,
  }) {
    final selected = _selectedPage == page;
    return Card(
      elevation: 0,
      color: selected ? Theme.of(context).colorScheme.secondaryContainer : null,
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        selected: selected,
        selectedColor: Theme.of(context).colorScheme.onSecondaryContainer,
        onTap: () => setState(() => _selectedPage = page),
      ),
    );
  }

  Widget _buildSelectedPage() {
    switch (_selectedPage) {
      case _SettingsPage.modelProvider:
        return _buildModelProviderPage();
      case _SettingsPage.about:
        return _buildAboutPage();
    }
  }

  Widget _buildModelProviderPage() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: <Widget>[
        _buildHeader(context),
        const SizedBox(height: 24),
        _buildProfileSection(),
        const SizedBox(height: 20),
        _buildDependencyPolicySection(),
        const SizedBox(height: 20),
        _buildModelSection(),
        const SizedBox(height: 20),
        _buildEmbeddingSection(),
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text('保存并生效'),
          ),
        ),
      ],
    );
  }

  Widget _buildAboutPage() {
    final textTheme = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Icon(Icons.info_outline),
                    const SizedBox(width: 12),
                    Text('关于', style: textTheme.titleLarge),
                  ],
                ),
                const SizedBox(height: 20),
                FutureBuilder<PackageInfo>(
                  future: PackageInfo.fromPlatform(),
                  builder: (context, snapshot) {
                    final packageInfo = snapshot.data;
                    final versionText = packageInfo == null
                        ? '读取中...'
                        : _formatFullVersion(packageInfo);
                    return SelectableText(
                      '版本 $versionText',
                      style: textTheme.bodyLarge,
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Icon(Icons.settings, size: 36),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('模型服务设置', style: textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  const Text(
                    '前端负责创建、删除、保存和选择多套模型配置；后端仍负责 Provider 的真实模型调用。保存后当前配置会传给通用 Python Runtime，并重新初始化当前角色会话。',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileSection() {
    return _SettingsSection(
      icon: Icons.manage_accounts_outlined,
      title: '模型配置档案',
      description: '前端管理多套模型配置。只有当前选中的配置会在保存后传给后端。',
      children: <Widget>[
        DropdownButtonFormField<String>(
          initialValue: _editingProfile.id,
          items: _settings.profiles
              .map(
                (profile) => DropdownMenuItem<String>(
                  value: profile.id,
                  child: Text(profile.name),
                ),
              )
              .toList(growable: false),
          decoration: const InputDecoration(
            labelText: '当前配置',
            border: OutlineInputBorder(),
          ),
          onChanged: (value) {
            if (value != null) {
              _selectProfile(value);
            }
          },
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _profileNameController,
          decoration: const InputDecoration(
            labelText: '配置名称',
            hintText: '例如 OpenAI 正式环境 / DeepSeek 日常 / 本地 Ollama',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            OutlinedButton.icon(
              onPressed: _createProfile,
              icon: const Icon(Icons.add),
              label: const Text('新建'),
            ),
            OutlinedButton.icon(
              onPressed: _duplicateProfile,
              icon: const Icon(Icons.copy),
              label: const Text('复制当前'),
            ),
            OutlinedButton.icon(
              onPressed: _settings.profiles.length <= 1 ? null : _deleteProfile,
              icon: const Icon(Icons.delete_outline),
              label: const Text('删除当前'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDependencyPolicySection() {
    return _SettingsSection(
      icon: Icons.extension_outlined,
      title: '可选依赖安装策略',
      description: 'Provider SDK 仍是 Python 后端可选依赖。前端只负责按策略触发后端准备依赖，不直接执行 pip 命令。',
      children: <Widget>[
        SegmentedButton<DependencyInstallPolicy>(
          segments: const <ButtonSegment<DependencyInstallPolicy>>[
            ButtonSegment<DependencyInstallPolicy>(
              value: DependencyInstallPolicy.auto,
              label: Text('自动'),
              icon: Icon(Icons.flash_on),
            ),
            ButtonSegment<DependencyInstallPolicy>(
              value: DependencyInstallPolicy.ask,
              label: Text('询问'),
              icon: Icon(Icons.help_outline),
            ),
            ButtonSegment<DependencyInstallPolicy>(
              value: DependencyInstallPolicy.manual,
              label: Text('手动'),
              icon: Icon(Icons.pan_tool_alt_outlined),
            ),
          ],
          selected: <DependencyInstallPolicy>{_dependencyInstallPolicy},
          onSelectionChanged: (selection) {
            setState(() => _dependencyInstallPolicy = selection.first);
          },
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            OutlinedButton.icon(
              onPressed: _checkingDependencies || widget.onCheckDependencies == null
                  ? null
                  : _checkDependencies,
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('检查当前配置依赖'),
            ),
            FilledButton.icon(
              onPressed: _checkingDependencies || widget.onInstallDependencies == null
                  ? null
                  : _installDependencies,
              icon: const Icon(Icons.download_outlined),
              label: const Text('安装当前配置所需依赖'),
            ),
          ],
        ),
        if (_checkingDependencies) ...<Widget>[
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
        ],
      ],
    );
  }

  Widget _buildModelSection() {
    return _SettingsSection(
      icon: Icons.smart_toy_outlined,
      title: '主聊天模型',
      description: '控制角色对话使用的服务商和模型。Provider 调用仍由 Python 后端执行。',
      children: <Widget>[
        _buildProviderDropdown(
          label: 'Provider',
          value: _provider,
          onChanged: (value) => setState(() => _provider = value),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _modelController,
          decoration: const InputDecoration(
            labelText: '模型名',
            hintText: '例如 deepseek-chat / gpt-4o / claude-sonnet-4-20250514',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _baseUrlController,
          decoration: const InputDecoration(
            labelText: 'Base URL（可选）',
            hintText: '兼容 OpenAI 的第三方服务可在这里填写 endpoint',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _apiKeyController,
          obscureText: _obscureApiKey,
          decoration: InputDecoration(
            labelText: 'API Key（本地 Ollama 可留空）',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: _obscureApiKey ? '显示 API Key' : '隐藏 API Key',
              onPressed: () => setState(() => _obscureApiKey = !_obscureApiKey),
              icon: Icon(_obscureApiKey ? Icons.visibility : Icons.visibility_off),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _temperatureController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Temperature（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _topPController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Top P（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _maxTokensController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Max Tokens（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _timeoutController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Timeout 秒（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _reasoningEffortController,
          decoration: const InputDecoration(
            labelText: 'Reasoning Effort（可选）',
            hintText: '例如 low / medium / high，按 Provider 支持情况填写',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('启用流式配置'),
          subtitle: const Text('是否向后端传递 stream=true。当前 UI 仍按非流式结果展示。'),
          value: _stream,
          onChanged: (value) => setState(() => _stream = value),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('启用 Think 参数'),
          subtitle: const Text('用于支持 think/reasoning 的 Provider。'),
          value: _think,
          onChanged: (value) => setState(() => _think = value),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('使用代理'),
          value: _useProxy,
          onChanged: (value) => setState(() => _useProxy = value),
        ),
      ],
    );
  }

  Widget _buildEmbeddingSection() {
    return _SettingsSection(
      icon: Icons.hub_outlined,
      title: 'Embedding 模型',
      description: '控制语义记忆检索使用的向量模型。留空时沿用后端默认配置。',
      children: <Widget>[
        _buildProviderDropdown(
          label: 'Embedding Provider',
          value: _embeddingProvider,
          includeDefault: true,
          onChanged: (value) => setState(() => _embeddingProvider = value),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _embeddingModelController,
          decoration: const InputDecoration(
            labelText: 'Embedding 模型名',
            hintText: '例如 text-embedding-3-small / BAAI/bge-m3 / gemini-embedding-001',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _embeddingBaseUrlController,
          decoration: const InputDecoration(
            labelText: 'Embedding Base URL（可选）',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _embeddingApiKeyController,
          obscureText: _obscureEmbeddingApiKey,
          decoration: InputDecoration(
            labelText: 'Embedding API Key（可选）',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: _obscureEmbeddingApiKey ? '显示 API Key' : '隐藏 API Key',
              onPressed: () => setState(() {
                _obscureEmbeddingApiKey = !_obscureEmbeddingApiKey;
              }),
              icon: Icon(
                _obscureEmbeddingApiKey ? Icons.visibility : Icons.visibility_off,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _embeddingDimensionsController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Embedding 维度（可选）',
                  hintText: 'OpenAI text-embedding-3 系列可填写缩短维度',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _embeddingTimeoutController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Embedding Timeout 秒（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Embedding 使用代理'),
          value: _embeddingUseProxy,
          onChanged: (value) => setState(() => _embeddingUseProxy = value),
        ),
      ],
    );
  }

  Widget _buildProviderDropdown({
    required String label,
    required String value,
    required ValueChanged<String> onChanged,
    bool includeDefault = false,
  }) {
    final values = <String>[if (includeDefault) '', ..._providers];
    final selected = values.contains(value) ? value : values.first;
    return DropdownButtonFormField<String>(
      initialValue: selected,
      items: values
          .map(
            (provider) => DropdownMenuItem<String>(
              value: provider,
              child: Text(provider.isEmpty ? '沿用主模型 / 后端默认' : provider),
            ),
          )
          .toList(growable: false),
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      onChanged: (value) {
        if (value != null) {
          onChanged(value);
        }
      },
    );
  }

  void _loadProfileIntoForm(ModelProfile profile) {
    _editingProfile = profile;
    _profileNameController.text = profile.name;
    _provider = _normalizeProvider(profile.model.provider, fallback: 'deepseek');
    _modelController.text = profile.model.model;
    _baseUrlController.text = profile.model.baseUrl;
    _apiKeyController.text = profile.model.apiKey;
    _temperatureController.text = profile.model.temperature;
    _topPController.text = profile.model.topP;
    _maxTokensController.text = profile.model.maxTokens;
    _timeoutController.text = profile.model.timeout;
    _reasoningEffortController.text = profile.model.reasoningEffort;
    _stream = profile.model.stream;
    _think = profile.model.think;
    _useProxy = profile.model.useProxy;
    _embeddingProvider = _normalizeProvider(
      profile.embedding.provider,
      fallback: 'openai',
      allowDefault: true,
    );
    _embeddingModelController.text = profile.embedding.model;
    _embeddingBaseUrlController.text = profile.embedding.baseUrl;
    _embeddingApiKeyController.text = profile.embedding.apiKey;
    _embeddingDimensionsController.text = profile.embedding.dimensions;
    _embeddingTimeoutController.text = profile.embedding.timeout;
    _embeddingUseProxy = profile.embedding.useProxy;
  }

  ModelProfile _profileFromForm() {
    return _editingProfile.copyWith(
      name: _profileNameController.text.trim(),
      model: ModelServiceSettings(
        provider: _provider,
        model: _modelController.text.trim(),
        baseUrl: _baseUrlController.text.trim(),
        apiKey: _apiKeyController.text.trim(),
        temperature: _temperatureController.text.trim(),
        topP: _topPController.text.trim(),
        maxTokens: _maxTokensController.text.trim(),
        timeout: _timeoutController.text.trim(),
        stream: _stream,
        think: _think,
        reasoningEffort: _reasoningEffortController.text.trim(),
        useProxy: _useProxy,
      ),
      embedding: EmbeddingServiceSettings(
        provider: _embeddingProvider,
        model: _embeddingModelController.text.trim(),
        baseUrl: _embeddingBaseUrlController.text.trim(),
        apiKey: _embeddingApiKeyController.text.trim(),
        dimensions: _embeddingDimensionsController.text.trim(),
        timeout: _embeddingTimeoutController.text.trim(),
        useProxy: _embeddingUseProxy,
      ),
      updatedAt: DateTime.now(),
    );
  }

  AppSettings _settingsWithCurrentForm() {
    return _settings
        .upsertProfile(_profileFromForm(), activate: true)
        .copyWith(dependencyInstallPolicy: _dependencyInstallPolicy);
  }

  void _selectProfile(String id) {
    final current = _profileFromForm();
    final updatedSettings = _settings.upsertProfile(current, activate: false);
    final nextProfile = updatedSettings.profiles.firstWhere(
      (profile) => profile.id == id,
      orElse: () => updatedSettings.activeProfile,
    );
    setState(() {
      _settings = updatedSettings.copyWith(activeProfileId: id);
      _loadProfileIntoForm(nextProfile);
    });
  }

  void _createProfile() {
    final now = DateTime.now();
    final currentSettings = _settingsWithCurrentForm();
    final profile = ModelProfile(
      id: 'profile_${now.microsecondsSinceEpoch}',
      name: '新配置 ${currentSettings.profiles.length + 1}',
      model: const ModelServiceSettings(provider: 'deepseek', model: 'deepseek-chat'),
      embedding: const EmbeddingServiceSettings(
        provider: 'openai',
        model: 'text-embedding-3-small',
      ),
      createdAt: now,
      updatedAt: now,
    );
    setState(() {
      _settings = currentSettings.upsertProfile(profile);
      _loadProfileIntoForm(profile);
    });
  }

  void _duplicateProfile() {
    final currentSettings = _settingsWithCurrentForm();
    final current = currentSettings.activeProfile;
    final duplicate = current.duplicate(
      id: 'profile_${DateTime.now().microsecondsSinceEpoch}',
      name: '${current.name} 副本',
    );
    setState(() {
      _settings = currentSettings.upsertProfile(duplicate);
      _loadProfileIntoForm(duplicate);
    });
  }

  void _deleteProfile() {
    final currentSettings = _settingsWithCurrentForm();
    if (currentSettings.profiles.length <= 1) {
      return;
    }
    final nextSettings = currentSettings.removeProfile(_editingProfile.id);
    setState(() {
      _settings = nextSettings;
      _loadProfileIntoForm(nextSettings.activeProfile);
    });
  }

  Future<void> _checkDependencies() async {
    final callback = widget.onCheckDependencies;
    if (callback == null) {
      return;
    }
    final nextSettings = _settingsWithCurrentForm();
    setState(() => _checkingDependencies = true);
    try {
      final status = await callback(nextSettings);
      if (!mounted) {
        return;
      }
      final message = status.allInstalled
          ? '当前配置依赖完整'
          : '缺少依赖：${status.missingProviders.join(', ')}';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('依赖检查失败：$error')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _checkingDependencies = false);
      }
    }
  }

  Future<void> _installDependencies() async {
    final callback = widget.onInstallDependencies;
    if (callback == null) {
      return;
    }
    final nextSettings = _settingsWithCurrentForm();
    setState(() => _checkingDependencies = true);
    try {
      final result = await callback(nextSettings);
      if (!mounted) {
        return;
      }
      final message = result.alreadyInstalled
          ? '当前配置依赖已经安装'
          : '依赖安装完成：${result.packages.join(', ')}';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('依赖安装失败：$error')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _checkingDependencies = false);
      }
    }
  }

  void _save() {
    final nextSettings = _settingsWithCurrentForm();
    final errors = nextSettings.activeProfile.validate();
    if (errors.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(errors.first)),
      );
      return;
    }

    Navigator.of(context).pop(nextSettings);
  }

  String _formatFullVersion(PackageInfo packageInfo) {
    final buildNumber = packageInfo.buildNumber.trim();
    if (buildNumber.isEmpty) {
      return packageInfo.version;
    }
    return '${packageInfo.version}+$buildNumber';
  }

  String _normalizeProvider(
    String value, {
    required String fallback,
    bool allowDefault = false,
  }) {
    final trimmed = value.trim();
    if (allowDefault && trimmed.isEmpty) {
      return '';
    }
    if (_providers.contains(trimmed)) {
      return trimmed;
    }
    return fallback;
  }
}

enum _SettingsPage { modelProvider, about }

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.icon,
    required this.title,
    required this.description,
    required this.children,
  });

  final IconData icon;
  final String title;
  final String description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(icon),
                const SizedBox(width: 12),
                Text(title, style: textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 8),
            Text(description),
            const SizedBox(height: 20),
            ...children,
          ],
        ),
      ),
    );
  }
}
