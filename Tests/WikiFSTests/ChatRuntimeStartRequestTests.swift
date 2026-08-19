import Foundation
import Testing
import WikiFSEngine
import WikiFSCore

@Suite struct ChatRuntimeStartRequestTests {
    @Test func roundTripsResolvedThinkingConfiguration() throws {
        let request = ChatRuntimeStartRequest(
            chatID: ChatID(rawValue: "chat"),
            generation: ChatSessionGenerationID(rawValue: "generation"),
            systemPrompt: "Prompt",
            providerID: ProviderID(rawValue: "provider"),
            modelID: ModelID(rawValue: "model"),
            existingProviderSessionID: AcpSessionID(rawValue: "session"),
            thinkingConfiguration: ResolvedThinkingConfiguration(
                optionID: ChatConfigurationOptionID(rawValue: "reasoning_mode"),
                desiredValueID: ChatConfigurationValueID(rawValue: "high"),
                priorEffectiveValueID: ChatConfigurationValueID(rawValue: "low")))

        let decoded = try JSONDecoder().decode(
            ChatRuntimeStartRequest.self,
            from: JSONEncoder().encode(request))
        #expect(decoded == request)
    }

    @Test func wireRequestContainsNoProcessLocalPreparation() throws {
        let request = ChatRuntimeStartRequest(
            chatID: ChatID(rawValue: "chat"),
            generation: ChatSessionGenerationID(rawValue: "generation"),
            systemPrompt: "Prompt",
            providerID: ProviderID(rawValue: "provider"),
            modelID: ModelID(rawValue: "model"),
            existingProviderSessionID: nil)
        let object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(Set(object.keys) == [
            "chatID", "generation", "systemPrompt", "providerID", "modelID",
        ])
        #expect(object["token"] == nil)
        #expect(object["providerPreparation"] == nil)
    }

    @Test func encodesStableSessionConfigWireShape() throws {
        let value = ResolvedThinkingConfiguration(
            optionID: ChatConfigurationOptionID(rawValue: "reasoning_mode"),
            desiredValueID: ChatConfigurationValueID(rawValue: "high"),
            priorEffectiveValueID: ChatConfigurationValueID(rawValue: "low"))
        let object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(value)) as? [String: String])
        #expect(object["mechanism"] == "sessionConfig")
        #expect(object["optionID"] == "reasoning_mode")
        #expect(object["desiredValueID"] == "high")
        #expect(object["priorEffectiveValueID"] == "low")
        #expect(object["modelID"] == nil)
    }

    @Test func encodesBoundedModelVariantsWireShape() throws {
        let value = ResolvedThinkingConfiguration(
            modelID: ModelID(rawValue: "gpt[high]"),
            desiredValueID: ChatConfigurationValueID(rawValue: "high"))
        let object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(value)) as? [String: String])
        #expect(object == [
            "mechanism": "modelVariants",
            "desiredValueID": "high",
            "modelID": "gpt[high]",
        ])
    }

    @Test func decodesLegacyPopulatedSessionConfigAsSessionConfig() throws {
        let data = Data(#"{"optionID":"thought_level","desiredValueID":"high","priorEffectiveValueID":"low"}"#.utf8)
        let decoded = try JSONDecoder().decode(ResolvedThinkingConfiguration.self, from: data)
        #expect(decoded.mechanism == .sessionConfig)
        #expect(decoded.optionID == ChatConfigurationOptionID(rawValue: "thought_level"))
        #expect(decoded.modelID == nil)
    }

    @Test(arguments: [
        #"{"mechanism":"unknown","desiredValueID":"high","optionID":"thought_level"}"#,
        #"{"mechanism":"sessionConfig","desiredValueID":"high","optionID":"thought_level","modelID":"gpt[high]"}"#,
        #"{"mechanism":"modelVariants","desiredValueID":"high","optionID":"thought_level"}"#,
        #"{"mechanism":"sessionConfig","optionID":"thought_level"}"#,
        #"{"desiredValueID":"high","modelID":"gpt[high]"}"#,
    ])
    func rejectsMalformedOrAmbiguousMechanismPayload(_ json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ResolvedThinkingConfiguration.self, from: Data(json.utf8))
        }
    }

    @Test func decodesLegacyPayloadWithoutThinkingConfiguration() throws {
        let data = Data(#"{"chatID":"chat","generation":"generation","systemPrompt":"Prompt","providerID":null,"modelID":null,"existingProviderSessionID":null}"#.utf8)
        let decoded = try JSONDecoder().decode(ChatRuntimeStartRequest.self, from: data)
        #expect(decoded.thinkingConfiguration == nil)
    }
}
