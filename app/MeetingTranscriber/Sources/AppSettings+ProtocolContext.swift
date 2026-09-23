#if !APPSTORE

    import Foundation

    extension AppSettings {
        /// Glossary for Claude CLI protocol generation: the template at
        /// `protocolContextPath` with `{{vocabulary}}` replaced by the custom
        /// vocabulary terms, so names and products follow the ASR dictionary.
        /// Nil when no template is configured or it cannot be read.
        func protocolContextText() -> String? {
            guard !protocolContextPath.isEmpty,
                  let template = try? String(contentsOfFile: protocolContextPath, encoding: .utf8),
                  !template.isEmpty
            else { return nil }
            let terms = customVocabularyFile.map { url in
                VocabularyFileAccess.withAccess(to: url) { scopedURL in
                    (try? String(contentsOf: scopedURL, encoding: .utf8)).map(WhisperVocabularyPrompt.terms(from:)) ?? []
                }
            } ?? []
            return ClaudeCLIProtocolGenerator.composeProtocolContext(template: template, vocabularyTerms: terms)
        }
    }

#endif
