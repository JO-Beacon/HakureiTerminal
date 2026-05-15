import 'package:flutter/material.dart';

import 'models/app_settings.dart';
import 'models/chat_character.dart';
import 'models/chat_message.dart';
import 'repositories/chat_repository.dart';
import 'screens/settings_screen.dart';
import 'services/python_bridge.dart';
import 'services/settings_store.dart';

void main() {
  runApp(const HakureiTerminalApp());
}

class HakureiTerminalApp extends StatelessWidget {
  const HakureiTerminalApp({super.key, this.enableBridge = true});

  final bool enableBridge;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HakureiTerminal',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xffc41e3a),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xffffb7c5),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: ChatScreen(enableBridge: enableBridge),
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, this.enableBridge = true});

  final bool enableBridge;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final PythonBridge _bridge;
  late final ChatRepository _repository;
  late final SettingsStore _settingsStore;
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  AppSettings _settings = AppSettings.defaultSettings;
  List<ChatCharacter> _characters = const <ChatCharacter>[];
  final List<ChatMessage> _messages = <ChatMessage>[];
  ChatCharacter? _selectedCharacter;
  bool _loading = true;
  bool _initializing = false;
  bool _sending = false;
  String? _error;
  String _bridgeLog = '';

  @override
  void initState() {
    super.initState();
    _bridge = PythonBridge();
    _repository = ChatRepository(_bridge);
    _settingsStore = SettingsStore();
    _bridge.stderr.listen((line) {
      if (!mounted) {
        return;
      }
      setState(() {
        _bridgeLog = (_bridgeLog + line).trim();
        if (_bridgeLog.length > 3000) {
          _bridgeLog = _bridgeLog.substring(_bridgeLog.length - 3000);
        }
      });
    });
    _loadSettingsAndCharacters();
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    _bridge.dispose();
    super.dispose();
  }

  Future<void> _loadSettingsAndCharacters() async {
    final settings = await _settingsStore.load();
    if (!mounted) {
      return;
    }
    setState(() => _settings = settings);
    if (widget.enableBridge) {
      await _loadCharacters();
    } else {
      setState(() => _loading = false);
    }
  }

  Future<void> _loadCharacters() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final characters = await _repository.listCharacters();
      setState(() {
        _characters = characters;
        _selectedCharacter = characters.isNotEmpty ? characters.first : null;
      });
      if (characters.isNotEmpty) {
        await _initializeCharacter(characters.first);
      }
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _initializeCharacter(ChatCharacter character) async {
    setState(() {
      _initializing = true;
      _selectedCharacter = character;
      _messages.clear();
      _error = null;
    });
    try {
      final ready = await _prepareDependenciesForCurrentSettings();
      if (!ready) {
        return;
      }
      await _repository.init(characterPath: character.path, settings: _settings);
      if (character.greeting.isNotEmpty) {
        _messages.add(
          ChatMessage(
            role: ChatMessageRole.assistant,
            content: character.greeting,
            createdAt: DateTime.now(),
          ),
        );
      }
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() => _initializing = false);
      }
      _scrollToBottom();
    }
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _sending || _initializing) {
      return;
    }

    setState(() {
      _sending = true;
      _error = null;
      _messages.add(
        ChatMessage(
          role: ChatMessageRole.user,
          content: text,
          createdAt: DateTime.now(),
        ),
      );
    });
    _messageController.clear();
    _scrollToBottom();

    try {
      final response = await _repository.sendMessage(text);
      setState(() {
        _messages.add(
          ChatMessage(
            role: ChatMessageRole.assistant,
            content: response.isEmpty ? '（没有收到回复）' : response,
            createdAt: DateTime.now(),
          ),
        );
      });
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
      _scrollToBottom();
    }
  }

  Future<bool> _prepareDependenciesForCurrentSettings() async {
    final status = await _repository.dependencyStatus(_settings);
    if (status.allInstalled) {
      return true;
    }

    final missing = status.missingProviders.join(', ');
    switch (_settings.dependencyInstallPolicy) {
      case DependencyInstallPolicy.auto:
        setState(() => _error = '正在安装缺失的 Python Provider 依赖：$missing');
        await _repository.installDependencies(_settings);
        if (mounted) {
          setState(() => _error = null);
        }
        return true;
      case DependencyInstallPolicy.ask:
        if (!mounted) {
          return false;
        }
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('需要安装 Provider 依赖'),
            content: Text('当前配置缺少 Python Provider SDK：$missing。是否现在安装？'),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('稍后'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('安装'),
              ),
            ],
          ),
        );
        if (!mounted) {
          return false;
        }
        if (confirmed != true) {
          setState(() => _error = '缺少 Python Provider SDK：$missing');
          return false;
        }
        await _repository.installDependencies(_settings);
        return true;
      case DependencyInstallPolicy.manual:
        setState(() => _error = '缺少 Python Provider SDK：$missing。请在设置页手动安装当前配置所需依赖。');
        return false;
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        return;
      }
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _openSettings() async {
    final saved = await Navigator.of(context).push<AppSettings>(
      MaterialPageRoute<AppSettings>(
        builder: (context) => SettingsScreen(
          initialSettings: _settings,
          onCheckDependencies: _repository.dependencyStatus,
          onInstallDependencies: _repository.installDependencies,
        ),
      ),
    );
    if (saved == null || !mounted) {
      return;
    }

    await _settingsStore.save(saved);
    if (!mounted) {
      return;
    }
    setState(() => _settings = saved);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('设置已保存，正在重新初始化当前角色')),
    );
    final selected = _selectedCharacter;
    if (widget.enableBridge && selected != null) {
      await _initializeCharacter(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('HakureiTerminal'),
        actions: <Widget>[
          IconButton(
            tooltip: '设置',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings),
          ),
          IconButton(
            tooltip: '重新加载角色',
            onPressed: _loading ? null : _loadCharacters,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Row(
        children: <Widget>[
          SizedBox(width: 280, child: _buildSidebar(context)),
          const VerticalDivider(width: 1),
          Expanded(child: _buildChatPane(context)),
        ],
      ),
    );
  }

  Widget _buildSidebar(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('角色', style: Theme.of(context).textTheme.titleLarge),
        ),
        if (_loading) const LinearProgressIndicator(),
        Expanded(
          child: ListView.builder(
            itemCount: _characters.length,
            itemBuilder: (context, index) {
              final character = _characters[index];
              return ListTile(
                selected: character.path == _selectedCharacter?.path,
                title: Text(character.name),
                subtitle: Text(character.id),
                onTap: _initializing
                    ? null
                    : () => _initializeCharacter(character),
              );
            },
          ),
        ),
        if (_bridgeLog.isNotEmpty)
          Flexible(
            child: SingleChildScrollView(
              child: ExpansionTile(
                title: const Text('Bridge 日志'),
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      _bridgeLog,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildChatPane(BuildContext context) {
    return Column(
      children: <Widget>[
        if (_selectedCharacter != null)
          Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: ListTile(
              title: Text(_selectedCharacter!.name),
              subtitle: Text(_selectedCharacter!.path),
              trailing: _initializing
                  ? const CircularProgressIndicator()
                  : null,
            ),
          ),
        if (_error != null)
          MaterialBanner(
            content: SelectableText(_error!),
            leading: const Icon(Icons.error_outline),
            actions: <Widget>[
              TextButton(
                onPressed: () => setState(() => _error = null),
                child: const Text('关闭'),
              ),
            ],
          ),
        Expanded(
          child: _messages.isEmpty
              ? const Center(child: Text('选择角色后开始对话'))
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) =>
                      _MessageBubble(message: _messages[index]),
                ),
        ),
        if (_sending) const LinearProgressIndicator(),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _messageController,
                  enabled:
                      !_sending && !_initializing && _selectedCharacter != null,
                  minLines: 1,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: '输入消息，按 Ctrl+Enter 发送或点击发送按钮',
                  ),
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _sending || _initializing ? null : _sendMessage,
                icon: const Icon(Icons.send),
                label: const Text('发送'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == ChatMessageRole.user;
    final colorScheme = Theme.of(context).colorScheme;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Card(
          color: isUser
              ? colorScheme.primaryContainer
              : colorScheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  isUser ? '你' : '角色',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: 6),
                SelectableText(message.content),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
