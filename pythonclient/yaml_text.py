"""YAML helpers for text columns that must not keep implicit scalar types."""


TEXT_VALUE_KEYS = {"slug", "body"}


def is_text_value_key(key):
    return isinstance(key, str) and (key in TEXT_VALUE_KEYS or key.endswith("_slug"))


def normalize_text_values(value):
    """Recursively coerce known text-field scalar values to strings.

    YAML loaders infer native scalar types for unquoted values. The course
    fixtures use keys like `slug`, `meeting_slug`, and `body` for PostgreSQL
    text columns, so normalize those values immediately after loading.
    """
    if isinstance(value, dict):
        normalized = {}
        for key, item in value.items():
            normalized_item = normalize_text_values(item)
            if is_text_value_key(key) and normalized_item is not None:
                normalized_item = coerce_text_scalar(key, normalized_item)
            normalized[key] = normalized_item
        return normalized
    if isinstance(value, list):
        return [normalize_text_values(item) for item in value]
    return value


def coerce_text_scalar(key, value):
    if isinstance(value, (dict, list, tuple)):
        raise TypeError(f"{key} must be a scalar text value")
    if isinstance(value, bool):
        return str(value).lower()
    return str(value)
