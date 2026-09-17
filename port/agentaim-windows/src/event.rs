use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const MAXIMUM_INPUT_BYTES: usize = 1_048_576;
pub const MAXIMUM_EVENT_BYTES: usize = 8_192;
pub const IPC_MAGIC: usize = 0x4141_494D;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HookEvent {
    pub provider: String,
    pub session_id: String,
    pub turn_id: Option<String>,
    pub hook_event_name: String,
    pub notification_type: Option<String>,
    #[serde(default)]
    pub is_interrupt: bool,
    pub timestamp: f64,
}

impl HookEvent {
    pub fn from_hook_json(input: &[u8], provider: &str, now: f64) -> Option<Self> {
        if input.is_empty() || input.len() > MAXIMUM_INPUT_BYTES {
            return None;
        }
        let value: Value = serde_json::from_slice(input).ok()?;
        let object = value.as_object()?;
        let session_id =
            bounded_string(object.get("session_id").or(object.get("sessionId"))?, 256)?;
        let hook_event_name = bounded_string(
            object
                .get("hook_event_name")
                .or(object.get("hookEventName"))?,
            128,
        )?;
        let turn_id = optional_bounded_string(
            object
                .get("turn_id")
                .or(object.get("turnId"))
                .or(object.get("prompt_id")),
            256,
        )?;
        let notification_type = optional_bounded_string(
            object
                .get("notification_type")
                .or(object.get("notificationType")),
            128,
        )?;
        let timestamp = object
            .get("timestamp")
            .and_then(|value| value.as_f64().or_else(|| value.as_str()?.parse().ok()))
            .filter(|value| value.is_finite())
            .unwrap_or(now);
        Some(Self {
            provider: provider.to_owned(),
            session_id,
            turn_id,
            hook_event_name,
            notification_type,
            is_interrupt: object
                .get("is_interrupt")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            timestamp,
        })
    }

    pub fn requests_attention(&self) -> bool {
        match self.hook_event_name.as_str() {
            "PermissionRequest" | "Elicitation" | "Stop" | "StopFailure" | "Interrupt" => true,
            "PostToolUseFailure" => self.is_interrupt,
            "Notification" => matches!(
                self.notification_type.as_deref(),
                Some("permission_prompt" | "idle_prompt")
            ),
            _ => false,
        }
    }

    pub fn starts_new_work(&self) -> bool {
        self.hook_event_name == "UserPromptSubmit"
    }
}

fn bounded_string(value: &Value, maximum_bytes: usize) -> Option<String> {
    let value = value.as_str()?;
    if value.is_empty() || value.len() > maximum_bytes {
        return None;
    }
    Some(value.to_owned())
}

fn optional_bounded_string(value: Option<&Value>, maximum_bytes: usize) -> Option<Option<String>> {
    let Some(value) = value else {
        return Some(None);
    };
    let value = value.as_str()?;
    if value.len() > maximum_bytes {
        return None;
    }
    Some((!value.is_empty()).then(|| value.to_owned()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitizer_keeps_only_allowlisted_fields() {
        let input = br#"{
            "session_id":"s1",
            "prompt_id":"p1",
            "hook_event_name":"UserPromptSubmit",
            "token":"must-not-leak",
            "timestamp":42
        }"#;
        let event = HookEvent::from_hook_json(input, "codex", 99.0).unwrap();
        assert_eq!(event.provider, "codex");
        assert_eq!(event.session_id, "s1");
        assert_eq!(event.turn_id.as_deref(), Some("p1"));
        let encoded = serde_json::to_string(&event).unwrap();
        assert!(!encoded.contains("token"));
        assert!(!encoded.contains("must-not-leak"));
    }

    #[test]
    fn rejects_missing_or_oversized_identifiers() {
        assert!(
            HookEvent::from_hook_json(br#"{"hook_event_name":"Stop"}"#, "codex", 0.0).is_none()
        );
        let input = format!(
            r#"{{"session_id":"{}","hook_event_name":"Stop"}}"#,
            "a".repeat(257)
        );
        assert!(HookEvent::from_hook_json(input.as_bytes(), "codex", 0.0).is_none());
    }

    #[test]
    fn event_mapping_matches_attention_contract() {
        let event = HookEvent::from_hook_json(
            br#"{"session_id":"s","hook_event_name":"Notification","notification_type":"permission_prompt"}"#,
            "claude",
            1.0,
        )
        .unwrap();
        assert!(event.requests_attention());
        assert!(!event.starts_new_work());
    }
}
