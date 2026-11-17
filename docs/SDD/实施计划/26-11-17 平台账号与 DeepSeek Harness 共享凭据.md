# 平台账号与 DeepSeek Harness 共享凭据实施计划

> 实现者按任务逐项完成。采用 `executing-plans` 在当前会话执行，或按用户选择采用 `subagent-driven-development`。对权限与凭据变更先写失败用例，再实现并验证。

**目标**　关闭公开本地建号，初始化默认管理员，验证平台管理员与项目 Owner 的管理权限，并在工作台和托管 SOP 中提供 DSH 共享推理。

**架构**　账号和共享配置归 `UsersRepo`。项目绑定归 `ProjectsRepo`。账号管理沿用 `usersHandlers`，密码认证沿用 `authHandlers`，新增独立共享推理 handler。工作台和托管 SOP 通过同一个共享推理组件借用短期凭据。

**技术栈**　Go、Gin、GORM、MySQL、bcrypt、原生 JavaScript、现有 DSH CLI。

**规格**　[平台账号与 DeepSeek Harness 共享凭据](../规格文档/26-11-17%20平台账号与%20DeepSeek%20Harness%20共享凭据.md)

## 全局约束

- 领域方法归各 Repo 和 handler，依赖显式注入。`Store` 保留装配职责。只用现有 GORM 增量 DDL 补表和列，数据修正与 seed 由运维显式执行 SQL。
- 代码、文档、SQL、构建产物和测试 fixture 使用示例凭据。部署人员安全输入约定的实际初始密码。禁用日志中的口令、共享 Key 和短期凭据回显。
- 先读根目录 `design.md`。登录和平台设置沿用现有 `web/` 渲染及请求封装。新增平台配置接口沿用现有路由鉴权和错误处理，推理入口按 DSH 使用的协议响应。
- 本期范围以规格为准。第三方登录、CodeBuddy、远程独立 Runner、Bot、报告和助手定时任务使用现行凭据规则。WorkBuddy 采用独立验证计划。
- 工作区已有改动。执行前保留用户改动，按任务只提交相关文件。

## 评审重点

| 输入或故障 | 预期行为 | 用例 |
| --- | --- | --- |
| 并发或重复初始化，`admin` 名称被非管理员身份占用 | 最多创建一个有效管理员，无静默接管，无密码覆盖 | 任务 1 |
| 管理员重置后，旧会话或平台 Token 再次访问 | 改密期间访问被拒绝，重置前凭据在改密后仍然失效 | 任务 1 |
| 管理员修改他人的项目时请求未提交 Owner 和成员 | 原 Owner 和成员保留，归档仍受既有条件限制 | 任务 2 |
| 共享凭据访问自定义上游、重定向或名单外模型 | 请求在服务端拒绝，目标地址和请求体均不回显 Key | 任务 3 |
| 托管执行经过沙箱网络，或重试时切换责任人、撤销共享 | 沙箱能到达签发凭据的实例。重试按当前责任人与配置重新判断 | 任务 4 |

## 任务 1　完成账号初始化、改密与注册下线

**文件**　`internal/repo/local_accounts.go`、`internal/repo/models.go`、`internal/auth/types.go`、`internal/httpapi/auth_password.go`、`internal/httpapi/auth_tokens.go`、`internal/httpapi/auth.go`、`internal/httpapi/platform_settings.go`、`internal/httpapi/server.go`、`internal/httpapi/auth_register.go`、`cmd/loopforge-account/main.go`、`migrations/seed/002_welcome_project.sql`、`web/login.js`、`web/login.html`、`web/app/workbench.js`、`docs/deployment.md`。

**对外契约**　`POST /api/auth/password` 保持正常登录响应。待改密时返回 `passwordChangeRequired: true` 并只设置独立的 HttpOnly、SameSite 改密 Cookie。`POST /api/auth/password/change` 读取该 Cookie，接收 `newPassword`，成功后清除改密 Cookie 并签发正常会话。`POST /api/auth/register` 和 `GET /api/auth/setup` 返回 `404`。`POST /api/platform/accounts` 继续接收 `loginName` 和现有的 `admin` 开关，初始密码取平台私有配置 `AGENTFLOW_INITIAL_ACCOUNT_PASSWORD`。

- [ ] 在 `internal/repo/local_accounts_test.go` 写 `TestBootstrapAdminIsIdempotent` 和 `TestLocalPasswordChangeIsSingleUse`。断言同名并发初始化不会产生两个账号，已有本地管理员密码保留，普通身份占用 `admin` 时返回冲突，改密并发提交只有一次成功。
- [ ] 在 `internal/httpapi/auth_password_test.go` 和现有平台设置测试增加 `TestTemporaryPasswordRequiresChange`、`TestPasswordResetInvalidatesOldCredentials`、`TestPublicAccountRegistrationClosed`。验证空库和有账号时旧入口均 `404`，即使设置旧注册开关也相同。验证待改密 Cookie 不能调用业务接口或签发 Token，改密成功后初始密码与旧 Cookie 失效，管理员重置前的会话与 Token 在重置后及再次改密后都失效。现有通过公开注册准备数据的测试改用 Repo fixture 或受权创建接口。
- [ ] 运行 `go test ./internal/repo ./internal/httpapi -run 'Test(BootstrapAdminIsIdempotent|LocalPasswordChangeIsSingleUse|TemporaryPasswordRequiresChange|PasswordResetInvalidatesOldCredentials|PublicAccountRegistrationClosed)$' -count=1`，确认用例命中预期缺失行为。
- [ ] 在 `UsersRepo` 实现 `BootstrapLocalAdmin(password string) (domain.User, error)`、`CreateTemporaryLocalAccount(login, password string, admin bool) (domain.User, error)`、`ResetTemporaryLocalPassword(userID int64, password string) error`、`ChangeTemporaryLocalPassword(userID, revision int64, password string) error`。为本地密码行增加默认 `false` 的待改密状态和默认 `0` 的密码版本。创建用户、写密码和授权在同一事务内，通过唯一登录名拒绝冲突。改密或重置使用密码版本做条件更新。重置对现有用户 Token 的撤销由 `TokensRepo` 的事务写路径承担，与密码重置使用同一事务，在 `newStore` 中单向注入依赖。正常会话沿用签名格式并记录本地密码版本，版本 `0` 兼容老会话。
- [ ] 在 `authHandlers` 实现 `authChangePassword(c *gin.Context)`。用独立签名用途和十分钟有效期绑定用户 ID 及当前密码版本，验证来源和密码长度并复用 IP 限流。检查 `requestUser` 与 `auth/current`、本地预览、网关交换和 Token 管理路径，统一拒绝待改密账号的业务身份。密码换新后旧会话必须仍被拒绝。移除注册和首次设置 handler、页面模式及旧开关依赖，迁移共用的登录名校验和体验项目加入逻辑到账号管理的现有归属。
- [ ] 为 `loopforge-account` 增加互斥的 `-bootstrap-admin` 模式，照旧从标准输入读取密码并调用 `BootstrapLocalAdmin`。文档给出显式初始化再导入体验项目的顺序。已有项目由现有幂等 SQL 保护。更新登录页的改密表单、成员管理创建表单和错误提示。`e2e/public/00-first-run.spec.mjs` 改为在启动夹具中显式建号，并在浏览器验收禁止注册和初次改密。确立旧路由在认证中间件后仍能得到 `404`。
- [ ] 对齐两种部署入口。在 `scripts/dev.sh` 将现有 `admin` 初始化切到 `-bootstrap-admin`。在 `compose.yaml` 和 `compose.dev.yaml` 移除旧注册开关，传入 `AGENTFLOW_INITIAL_ACCOUNT_PASSWORD`，并在部署说明给出容器内显式运行账号命令的方式。发行镜像的构建清单应包含 `loopforge-account`。在 `e2e/public/README.md` 同步空库夹具和改密后的账号准备步骤。
- [ ] 重跑定向 Go 用例以及 `go test ./internal/auth ./internal/repo ./internal/httpapi`。运行 `npm --prefix webtest test` 和 `e2e/public/README.md` 的隔离实例用例。将账号改动单独提交。

## 任务 2　验收所有项目的管理权限

**文件**　`internal/httpapi/projects.go`、`internal/httpapi/project_write_access.go`、`internal/httpapi/catalog.go`、`web/app/projects.js`。测试沿用 `internal/httpapi/project_write_access_test.go`、`project_delete_test.go`、`repository_authz_test.go` 和 `webtest/tests/projects-repos.test.mjs`。

- [ ] 增加 `TestPlatformAdminManagesProjectsWithoutMembership`。准备两个普通 Owner 各建一项目，验证两人能管理自己的项目。平台管理员读取列表与详情并管理他人的设置、成员和仓库，完成归档和恢复。更新请求省略 `ownerId` 和 `members` 时保留原值，并检查普通用户不能修改、归档或恢复他人的项目。
- [ ] 在现有页面测试验证全量视图显示两个项目，管理员可以进入两个项目的管理入口。Owner 仍有管理入口，其他普通用户受现有条件限制。运行 `go test ./internal/httpapi -run 'Test(PlatformAdminManagesProjectsWithoutMembership|.*Project.*|.*Repository.*)$' -count=1` 与 `node --test webtest/tests/projects-repos.test.mjs`。
- [ ] 对失败的授权用当前平台角色判断补齐，项目 Owner 仍采用现有归属规则。通过的现有行为由用例锁定。重跑相关验证并单独提交。

## 任务 3　管理共享配置并提供受限推理入口

**文件**　新增 `internal/repo/deepseek_sponsor.go`、`internal/httpapi/deepseek_inference.go`、`internal/deepseek/shared_inference.go`。修改 `internal/repo/models.go`、`internal/httpapi/platform_settings.go`、`internal/httpapi/server.go`、`internal/httpapi/auth_tokens.go`、`web/app/workbench.js`、`docs/api/openapi.yaml`。

**接口**　平台设置用 `GET`、`PUT`、`DELETE /api/platform/deepseek-harness-key`。写入 `apiKey`、有序 `models`，更新时省略 `apiKey` 表示保留。读取 `configured` 和 `models`，删除停用共享。DSH 用 `POST /api/internal/deepseek/v1/chat/completions` 发起推理，授权采用 `Authorization: Bearer <lease>`。共享组件暴露 `Acquire(ctx context.Context, userID int64, executionID, requestedModel string) (credential runtime.ProviderCredential, model string, release func(), err error)`，由任务 4 接入。

- [ ] 新建 `TestPlatformDeepSeekKeyAdministration` 和 `TestSharedDeepSeekInferenceBoundaries`。前者覆盖普通用户访问 `403`、跨源 Cookie 写入 `403`、空白名单拒绝、轮换与停用、响应不回显 Key。后者用 `httptest` 验证目标和请求方法固定、禁止重定向、请求模型必须属于白名单且匹配凭据、无效与已释放凭据拒绝、流式转发保留增量输出。
- [ ] 运行 `go test ./internal/httpapi ./internal/deepseek -run 'Test(PlatformDeepSeekKeyAdministration|SharedDeepSeekInferenceBoundaries)$' -count=1`。先建立薄接口后加测试，使失败直接指向行为。
- [ ] 在 `UsersRepo` 以单条记录存储 Key、模型顺序和管理元数据，读取状态与读取秘密使用不同类型，管理接口复用 `platformAdminWrite`。停用使后续请求失败，轮换让下一次请求读取新 Key。用单独迁移编号提供运维需要的初始 DDL，由 GORM 补表规则与手动 SQL 保持兼容。
- [ ] 创建独立 `deepSeekInferenceHandlers`。在平台进程注册精确推理路由，允许其自行验证短期 Bearer，通用 Cookie/API Token 无效。由服务端构造固定上游请求，将目标设置为 `https://api.deepseek.com/chat/completions`，只透传协议需要的头和字段，限制请求体和并行流，拒绝重定向。验证通过后转发响应与 SSE，脱敏上游错误。用请求上下文、中止信号与可关闭的流限制资源。原有 Basic Auth 启用时，精确推理路由仍由自己的凭据保护。
- [ ] `Acquire` 哈希保存 `crypto/rand` 生成的随机凭据，绑定用户、执行和选定模型，同时记录绝对有效期。上下文结束或显式释放时移除租约。每次请求重新读取共享配置及账号状态。短期凭据通过运行时凭据传给 DSH，使用固定的 OpenAI Chat Completions 协议与平台推理地址。真实 Key 仅存在于存储和上游请求。关闭共享时，已开始的流允许结束。
- [ ] 添加管理面板和 OpenAPI 项，运行定向 Go 用例和 `npm --prefix webtest test`。单独提交共享配置和推理入口。

## 任务 4　对话和托管 SOP 接入共享推理

**文件**　`cmd/agentflow/main.go`、`internal/httpapi/assistant_engines.go`、`internal/httpapi/assistant.go`、`internal/httpapi/assistant_engine_agentcli.go`、`internal/httpapi/assistant_diagnostics.go`、`internal/engine/run_environment.go`、`internal/engine/node_execute.go`、`internal/runtime/agent_cli.go`、`internal/runtime/command_binding.go`、`docs/deployment.md`。使用现有 `ProviderCredential`、`AgentCLIOptions` 和 DSH 模型配置。

- [ ] 新增 `TestAssistantDeepSeekSharedFallback` 和 `TestHostedSOPDeepSeekSharedFallback`。断言个人 Key 及个人地址优先，个人 Key 失败时没有回退。没有个人 Key 时只列出共享模型，默认取首项，禁止名单外模型。托管 SOP 按需求责任人选择凭据，缺省时沿用项目 Owner。重试后改用当前责任人的配置，并验证独立 Runner 的任务载荷里没有共享凭据。
- [ ] 运行 `go test ./internal/httpapi ./internal/engine -run 'Test(AssistantDeepSeekSharedFallback|HostedSOPDeepSeekSharedFallback)$' -count=1`，确认缺少回退时测试失败。
- [ ] 装配一份共享组件并注入 API 和引擎。仅工作台 DSH 对话启动和托管 DSH 节点启动调用 `Acquire`，退出后释放。工作台模型列表和是否已配置由共享状态决定，模型发现不会拿真实 Key。托管执行在节点启动时以当前责任人和模型解析，避免把凭据写进 SOP 定义、运行快照或随 Runner 请求下发。
- [ ] 部署侧用 `AGENTFLOW_DEEPSEEK_RELAY_URL` 提供沙箱可访问的实例地址。原生安装在同一网络命名空间用回环地址，单实例 Compose 用现有平台服务地址和沙箱网络。多实例配置实例地址，负载均衡不得把租约请求路由到其他实例。参数无效、地址不可达或实例不可用时给出可定位的错误。清除注入路径上可覆盖上游的代理、模型端点和 DSH 环境变量，检查日志、诊断及错误输出对真实 Key 和租约的脱敏。
- [ ] 重跑定向用例，再运行 `go test ./internal/httpapi ./internal/engine ./internal/runtime ./internal/repo ./internal/deepseek ./docs/api`。使用隔离实例的模拟上游跑一次真实 DSH 对话和托管 SOP，核对流式回复、模型限制、停用和工作区文件均无真实 Key。按部署文档启用一次 Docker 沙箱验证，并单独提交接入改动。

## 规格覆盖

| 规格项 | 对应任务 |
| --- | --- |
| 注册关闭、初始化、初始密码、改密与升级 | 1 |
| 平台管理员管理所有项目、Owner 权限保留 | 2 |
| 共享配置、转发授权、模型白名单、轮换和停用 | 3 |
| 对话与托管 SOP 的优先级、执行凭据与沙箱连通性 | 4 |
| WorkBuddy | 后续独立验证 OAuth、云任务和 ACP 对话 |
