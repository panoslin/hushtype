# Hushtype Cloud（参考实现）

让用户不用自带 API key：Mac App 把请求发到这里，由服务器带上你的 Anthropic key 转发。

## 它做什么
- 校验用户令牌（KV `TOKENS`：`token:<令牌>` → `{"user":"…","daily":2000}`）
- 只放行听写需要的字段和两个模型（Sonnet 5.5 / Haiku 5.5），`max_tokens` ≤ 8192，请求体 ≤ 64 KB
- 每个用户每天的请求数上限（默认 2000；缓存预热请求不计数）
- key 只存在服务器 secret 里，客户端永远拿不到

## 部署
```bash
cp wrangler.toml.example wrangler.toml   # 填两个 KV namespace id
wrangler kv namespace create TOKENS
wrangler kv namespace create USAGE
wrangler secret put ANTHROPIC_API_KEY
wrangler deploy
# 发一个令牌
wrangler kv key put --binding TOKENS "token:$(openssl rand -hex 24)" '{"user":"alice","daily":2000}'
```
然后在 Hushtype › 设置 › 整理与模型 选「Hushtype Cloud / 自建代理」，填 Worker 地址和令牌。

## 还没做（上线计费前需要）
- 账号注册 / 登录与令牌发放（目前手动写 KV）
- 订阅计费（Stripe）与用量按月结算
- KV 计数是近似的；严格计费换成 Durable Objects
