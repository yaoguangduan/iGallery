// 简单的 Bearer token 鉴权。
// 启动时未指定 token 则不启用；启用后所有 /v1/* 请求(除 /v1/auth)必须带 Authorization: Bearer <token>

use axum::{
    extract::State,
    http::{header, Request, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
    Json,
};

use crate::AppState;

pub async fn require_token(
    State(state): State<AppState>,
    req: Request<axum::body::Body>,
    next: Next,
) -> Response {
    let Some(expected) = state.token.as_deref() else {
        return next.run(req).await;
    };

    // /v1/auth 不校验，用于探测是否需要 token
    let path = req.uri().path();
    if path == "/v1/auth" {
        return next.run(req).await;
    }

    let ok = req
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.strip_prefix("Bearer "))
        .map(|t| t == expected)
        .unwrap_or(false);

    if ok {
        next.run(req).await
    } else {
        (StatusCode::UNAUTHORIZED, Json(serde_json::json!({"error": "unauthorized"}))).into_response()
    }
}

// GET /v1/auth — 探测是否需要鉴权。响应 200 {required: bool, authorized: bool}
pub async fn auth_probe(
    State(state): State<AppState>,
    req: Request<axum::body::Body>,
) -> impl IntoResponse {
    let required = state.token.is_some();
    let authorized = if let Some(expected) = state.token.as_deref() {
        req.headers()
            .get(header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .and_then(|s| s.strip_prefix("Bearer "))
            .map(|t| t == expected)
            .unwrap_or(false)
    } else {
        true
    };
    Json(serde_json::json!({"required": required, "authorized": authorized}))
}
