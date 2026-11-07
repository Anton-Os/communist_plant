import 'package:ollama_dart/ollama_dart.dart';

class Ollama_Service {
  Ollama_Service({ this.modelName = "qwen3" }){
    client ??= OllamaClient(
        config: OllamaConfig(baseUrl: urlPath,
        timeout: Duration(seconds: 10)
    ));
    init(); // initializes the version and models
  }

  Future<void> init() async {
    // Provide version information
    final version = await client?.version.get();
    print('Ollama version: ${version?.version}\n');

    // List available models
    final models = await client?.models.list();
    print('Selected model $modelName\nAvailable models:');
    for (final model in models?.models ?? <ModelSummary>[]) print('  - ${model.name}');
  }

  Future<String?> promptToTxt(String prompt, { String sysInstructions = "" }) async {
    List<ChatMessage> messages = <ChatMessage>[ ChatMessage.user(prompt) ];
    if(sysInstructions.isNotEmpty) messages.insert(0, ChatMessage.system(sysInstructions));

    return getResponse(messages);
  }

  Future<String?> getResponse(List<ChatMessage> messages) async {
    final chatResponse = await client?.chat.create(
      request: ChatRequest(model: modelName, messages: messages),
    );

    String? result = (chatResponse?.message != null)? chatResponse!.message!.content : "";
    if(result != null) print("Ollama response is " + result);
    return result;
  }

  String modelName;
  OllamaClient? client = null;
  String urlPath = 'http://10.0.0.92:11434';
}