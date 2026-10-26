# 設計書セットの使い方

このフォルダは週間献立・買い物リストアプリの設計書です。

- `../CLAUDE.md`：Claude Codeが守る作業ルール
- `requirements.md`：機能・非機能要件
- `screen-design.md`：画面と画面遷移
- `data-design.md`：データモデルと数量計算ルール
- `technical-design.md`：技術構成・処理方式
- `test-design.md`：テスト方針・初期テスト一覧
- `development-plan.md`：環境準備と段階的な開発手順

## 配置
`CLAUDE.md`をXcodeプロジェクトのルート（`.xcodeproj`があるフォルダ）に置き、`docs`フォルダも同じルートに置きます。

## Claude Codeへの最初の依頼例
設計書を配置したら、プロジェクトのルートでClaude Codeを起動し、次のように依頼してください。

「まずCLAUDE.mdとdocs内の設計書をすべて読んでください。まだコードは変更せず、現在のXcodeプロジェクト構成、Xcode/Swift/Deployment Target、設計書との不足・不一致、実装を始める前に確認が必要な点を報告してください。要件や設計を独断で変更しないでください。」

報告内容を確認してから、第0段階の環境確認を進めます。
