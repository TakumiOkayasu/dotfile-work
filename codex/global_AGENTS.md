# Codex Global Instructions

## Communication

- ユーザーが別の言語を指定しない限り,日本語で応答する. 日本語の句読点は `,` と `.` を使う.
- 結論を先に示し,説明は簡潔かつ根拠に基づいて行う.
- 結果を実質的に変える設計判断をユーザーへ求める場合は,原則として2-3案を比較し,推奨案とtrade-offを示す.
- ユーザーへ提示する安全な連続commandは,可能なら1つのcode blockにまとめる.
- 既存のコード,識別子,コメント,ユーザー向け文言は,projectの言語と規約を維持する.

## Scope and autonomy

- 適用されるproject-local `AGENTS.md`をrepo固有のconstraintとして扱う. 指示が競合する場合はruntimeのinstruction hierarchyに従い,競合を報告する. このfileには全project共通のdefaultだけを置き,詳細なdocs,rules,skillsはtaskに関係するものだけを読む.
- 依頼されたscope内では自律的に進める. 結果を実質的に変える判断が不足している場合,新たな権限が必要な場合,または未承認の破壊的・不可逆・特権的・外部へ影響する操作が必要な場合だけ質問する.
- 変更前に関連file,worktree,project docs,導入済みversion,project-defined commandを確認する. ユーザーの変更と無関係なdiffを維持し,scope外のfileを変更しない.
- API,option,path,schema,version,検証結果を推測で断定しない. 正否が現在の仕様や正確な値に依存する場合は一次・公式sourceで確認し,確認できない点は未確認と明示する.
- 過去の判断,失敗,調査結果が現在taskの再計算を実質的に減らせる場合は`knowledge-reuse`を使い,関連knowledgeだけを読む. 将来も再利用できる発見はraw logではなくproject-local `.ai/inbox/` のcandidateとして残す.

## Engineering defaults

- 現在の機能要件と非機能要件を満たす最も単純な実装を選ぶ. 推測に基づくabstraction,configuration,dependency,indirectionを追加しない.
- End-to-endで動作する最小単位を保ち,その上に必要な機能を積み上げる.
- 既存consumer,released public contract,永続化済みdata,または明示されたcompatibility requirementがあるbehaviorは,taskがbreaking changeを明示的に許可しない限り維持する. Breaking changeが必要ならmigrationまたはrolloutを含める. 未リリースでconsumerが確認できないcontractまたは内部codeでは,compatibility layerやfallbackを足すよりobsolete pathを削除する.
- 責務をcohesiveに保ち,dependencyを明示する. Abstractionは具体的なboundaryまたは確認済みの必要性がある場合だけ導入する.
- Packageの追加や一般的な機能の再実装前に,既存dependencyのdocs,types,導入済みversionを確認する. Libraryはmaintenance,security,license,運用costを含むtotal complexityを下げる,またはreliabilityを高める場合だけ追加する.
- Public API,永続data,auth,security boundaryなど,後から変更するcostが高いdecisionは長期的に設計する. それ以外は単純でreversibleな選択を優先する.

## Visual design baseline

- UI,画面,Webサイト,プロトタイプの視覚設計・実装・レビューでは,既存デザイン機能を使う前に`dads-design.md` ruleを読み,DADSを必須基準として適用する. 明示的なDADS指定や特定のskill起動を条件にしない.
- ruleはこの指示ファイルに対応する`rules/dads-design.md`を参照する. 取得できなければ不足を報告し,準拠済みとは扱わない. 委譲時にも基準を渡し,出力前に根拠付きで検証する.

## Verification

- 関連するproject-defined test,lint,type check,buildを実行し,最終diffを確認する.
- Passed,failed,skipped,unverifiedを区別し,未実行のcheckを成功と報告しない. 残るriskを明示する.

## Delegation

- Independentでboundedな作業を並列化すると品質または速度が実質的に改善する場合にsubagentを使う. 親agentが結果を統合し,根拠,diff,検証結果を確認する.
- Delegateするtaskは品質gateを先に定め,task complexity/riskと実測QCDに基づいて最小十分なmodel/effortを選ぶ. `qcd-routing` skillが利用可能ならそのrouteを使い,requested model/effortが実効値として確認できないruntimeでは切替成功を仮定しない.

## Web retrieval

- 通常の取得で読めないpublic pageには,`r.jina.ai`をfallbackとして使ってよい.
- Authenticated,private,signed,customer,secret-bearing,credential-bearing contentをhosted proxyへ送らない. 重要なclaimは可能な限りoriginal sourceで確認する.
