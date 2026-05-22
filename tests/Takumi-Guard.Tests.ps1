# Pester tests for Takumi Guard install/uninstall logic.
# Run on GitHub Actions (.github/workflows/test-takumi-guard.yml).
#
# Tests cover the pure helper functions (no Windows-specific paths needed)
# and end-to-end Apply-ManagedConfig / Restore-Config behavior against
# arbitrary temp paths. Compatible with Pester v5+.

# Pester v5: top-level コードは Discovery phase で評価され It block scope に
# 関数定義を届けない。helper の dot-source と New-TempDir は **BeforeAll** に
# 入れる。ファイル top-level の BeforeAll はファイル内の全 Describe で共有される。

BeforeAll {
    $RepoRoot        = (Resolve-Path "$PSScriptRoot/..").Path
    $InstallScript   = Join-Path $RepoRoot "scripts/apps/takumi_guard/install.ps1"
    $UninstallScript = Join-Path $RepoRoot "scripts/apps/takumi_guard/uninstall.ps1"
    # install.ps1: Apply-ManagedConfig 等の helper
    . $InstallScript
    # uninstall.ps1: Restore-Config (install.ps1 には無い)
    . $UninstallScript

    function New-TempDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ("tg-test-" + [Guid]::NewGuid().ToString("N"))
        New-Item -Path $d -ItemType Directory -Force | Out-Null
        return $d
    }
}

# ---------------------------------------------------------------------------
# Helper: Read-LinesOrEmpty / Write-FileNoBom
# ---------------------------------------------------------------------------

Describe "Read-LinesOrEmpty" {
    It "returns empty array when file does not exist" {
        $result = Read-LinesOrEmpty "/nonexistent/path/xyz123"
        $result | Should -HaveCount 0
    }

    It "returns lines from existing file" {
        $tmp = New-TempDir
        try {
            $path = Join-Path $tmp "file.txt"
            "line1`nline2`nline3" | Set-Content -LiteralPath $path
            $result = Read-LinesOrEmpty $path
            $result | Should -HaveCount 3
            $result[0] | Should -Be "line1"
            $result[2] | Should -Be "line3"
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force
        }
    }
}

Describe "Write-FileNoBom" {
    It "writes UTF-8 without BOM" {
        $tmp = New-TempDir
        try {
            $path = Join-Path $tmp "file.txt"
            Write-FileNoBom -Path $path -Lines @("hello", "world")
            $bytes = [System.IO.File]::ReadAllBytes($path)
            # 先頭 3 byte が EF BB BF (BOM) でないこと
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
            # 中身が "hello" で始まる
            $bytes[0] | Should -Be 0x68  # 'h'
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force
        }
    }
}

# ---------------------------------------------------------------------------
# Helper: Remove-ManagedBlock
# ---------------------------------------------------------------------------

Describe "Remove-ManagedBlock" {
    It "returns input unchanged when no block markers" {
        $input = @("foo", "bar", "baz")
        $result = Remove-ManagedBlock -Lines $input
        $result | Should -HaveCount 3
        $result[1] | Should -Be "bar"
    }

    It "removes a complete block including its boundary lines" {
        $input = @(
            "before"
            "# === BEGIN TakumiGuard ==="
            "managed1"
            "managed2"
            "# === END TakumiGuard ==="
            "after"
        )
        $result = Remove-ManagedBlock -Lines $input
        $result | Should -HaveCount 2
        $result[0] | Should -Be "before"
        $result[1] | Should -Be "after"
    }

    It "handles block at start of file" {
        $input = @(
            "# === BEGIN TakumiGuard ==="
            "x"
            "# === END TakumiGuard ==="
            "after"
        )
        $result = Remove-ManagedBlock -Lines $input
        $result | Should -HaveCount 1
        $result[0] | Should -Be "after"
    }

    It "preserves all lines if BEGIN is unmatched (defensive)" {
        # END なしで開始した場合、最後まで block 内扱いで丸ごと消える。
        # malformed input への defensive 動作の確認。
        $input = @("foo", "# === BEGIN TakumiGuard ===", "x", "y")
        $result = Remove-ManagedBlock -Lines $input
        $result | Should -HaveCount 1
        $result[0] | Should -Be "foo"
    }
}

# ---------------------------------------------------------------------------
# Helper: Restore-DisabledLines
# ---------------------------------------------------------------------------

Describe "Restore-DisabledLines" {
    It "strips disabled prefix and restores original line" {
        $input = @(
            "ok-line"
            "# [TakumiGuard-disabled] foo=bar"
            "# [TakumiGuard-disabled] baz=qux"
            "another"
        )
        $result = Restore-DisabledLines -Lines $input
        $result[0] | Should -Be "ok-line"
        $result[1] | Should -Be "foo=bar"
        $result[2] | Should -Be "baz=qux"
        $result[3] | Should -Be "another"
    }

    It "leaves normal comments untouched" {
        $input = @("# normal comment", "# [TakumiGuard-disabled] x=1")
        $result = Restore-DisabledLines -Lines $input
        $result[0] | Should -Be "# normal comment"
        $result[1] | Should -Be "x=1"
    }
}

# ---------------------------------------------------------------------------
# Helper: Disable-MatchingKeys
# ---------------------------------------------------------------------------

Describe "Disable-MatchingKeys (no section / top-level)" {
    It "comments out matching top-level keys" {
        $input = @(
            "registry=https://npmjs.org/"
            "save-exact=true"
            "min-release-age=10"
        )
        $result = Disable-MatchingKeys -Lines $input -Section "" `
            -Keys @("registry", "min-release-age") -Separator "="
        $result[0] | Should -Be "# [TakumiGuard-disabled] registry=https://npmjs.org/"
        $result[1] | Should -Be "save-exact=true"
        $result[2] | Should -Be "# [TakumiGuard-disabled] min-release-age=10"
    }

    It "does not match indented YAML keys (nested under another key)" {
        # pnpm config.yaml で hooks: の下の beforeInstall: registry: ... を誤検出しないこと
        $input = @(
            "hooks:"
            "  registry: should-not-be-disabled"
        )
        $result = Disable-MatchingKeys -Lines $input -Section "" `
            -Keys @("registry") -Separator ":"
        $result[0] | Should -Be "hooks:"
        $result[1] | Should -Be "  registry: should-not-be-disabled"
    }
}

Describe "Disable-MatchingKeys (with section)" {
    It "only comments inside the target section" {
        $input = @(
            "[other]"
            "index-url = https://untouched/"
            "[global]"
            "index-url = https://target/"
            "timeout = 60"
            "[third]"
            "index-url = https://also-untouched/"
        )
        $result = Disable-MatchingKeys -Lines $input -Section "global" `
            -Keys @("index-url") -Separator "="
        $result[1] | Should -Be "index-url = https://untouched/"
        $result[3] | Should -Be "# [TakumiGuard-disabled] index-url = https://target/"
        $result[4] | Should -Be "timeout = 60"
        $result[6] | Should -Be "index-url = https://also-untouched/"
    }

    It "allows leading whitespace for keys within section" {
        # pip.ini や TOML はインデントを許容するので拾う
        $input = @(
            "[global]"
            "    index-url = https://x/"
        )
        $result = Disable-MatchingKeys -Lines $input -Section "global" `
            -Keys @("index-url") -Separator "="
        $result[1] | Should -Be "# [TakumiGuard-disabled]     index-url = https://x/"
    }
}

# ---------------------------------------------------------------------------
# Helper: Add-ManagedBlock
# ---------------------------------------------------------------------------

Describe "Add-ManagedBlock (no section)" {
    It "appends block at end of file" {
        $input = @("foo", "bar")
        $settings = [ordered]@{ "key" = "value" }
        $result = Add-ManagedBlock -Lines $input -Section "" -Settings $settings -Separator "="
        $result[-3] | Should -Be "# === BEGIN TakumiGuard ==="
        $result[-2] | Should -Be "key=value"
        $result[-1] | Should -Be "# === END TakumiGuard ==="
    }
}

Describe "Add-ManagedBlock (with section)" {
    It "inserts block immediately after existing section header" {
        $input = @("[global]", "timeout = 60")
        $settings = [ordered]@{ "index-url" = "https://x/" }
        $result = Add-ManagedBlock -Lines $input -Section "global" -Settings $settings -Separator " = "
        $result[0] | Should -Be "[global]"
        $result[1] | Should -Be "# === BEGIN TakumiGuard ==="
        $result[2] | Should -Be "index-url = https://x/"
        $result[3] | Should -Be "# === END TakumiGuard ==="
        $result[4] | Should -Be "timeout = 60"
    }

    It "appends section + block at end if section not present" {
        $input = @("[other]", "foo = 1")
        $settings = [ordered]@{ "index-url" = "https://x/" }
        $result = Add-ManagedBlock -Lines $input -Section "global" -Settings $settings -Separator " = "
        ($result -join "`n") | Should -Match "\[global\][\s\S]*BEGIN TakumiGuard[\s\S]*index-url = https://x/[\s\S]*END TakumiGuard"
        # [other] block remains intact
        $result[0] | Should -Be "[other]"
        $result[1] | Should -Be "foo = 1"
    }
}

# ---------------------------------------------------------------------------
# Integration: Apply-ManagedConfig + Restore-Config (round-trip)
# ---------------------------------------------------------------------------

Describe "Apply-ManagedConfig + Restore-Config round-trip" {
    It "preserves existing non-Takumi settings in pip.ini" {
        $tmp = New-TempDir
        try {
            $pipini = Join-Path $tmp "pip.ini"
            $original = @(
                "[global]"
                "index-url = https://corp.example/simple/"
                "timeout = 60"
                "trusted-host = corp.example"
            )
            Write-FileNoBom -Path $pipini -Lines $original

            Apply-ManagedConfig -Path $pipini -Section "global" `
                -Settings ([ordered]@{ "index-url" = "https://pypi.flatt.tech/simple/" }) `
                -Separator " = "

            $after = Get-Content $pipini
            # ours is in
            ($after -join "`n") | Should -Match "index-url = https://pypi\.flatt\.tech/simple/"
            # original is disabled
            ($after -join "`n") | Should -Match "# \[TakumiGuard-disabled\] index-url = https://corp\.example/simple/"
            # untouched preserved
            $after | Should -Contain "timeout = 60"
            $after | Should -Contain "trusted-host = corp.example"

            # Restore should bring back exact original
            Restore-Config -Path $pipini
            $restored = Get-Content $pipini
            $restored[0] | Should -Be "[global]"
            $restored[1] | Should -Be "index-url = https://corp.example/simple/"
            $restored[2] | Should -Be "timeout = 60"
            $restored[3] | Should -Be "trusted-host = corp.example"
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force
        }
    }

    It "creates file from scratch when not present" {
        $tmp = New-TempDir
        try {
            $path = Join-Path $tmp "subdir/.npmrc"
            Apply-ManagedConfig -Path $path -Section "" `
                -Settings ([ordered]@{ "registry" = "https://npm.flatt.tech/" }) `
                -Separator "="
            Test-Path $path | Should -BeTrue
            $content = Get-Content $path
            ($content -join "`n") | Should -Match "registry=https://npm\.flatt\.tech/"
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force
        }
    }

    It "is idempotent (re-applying same config doesn't duplicate)" {
        $tmp = New-TempDir
        try {
            $path = Join-Path $tmp ".npmrc"
            Apply-ManagedConfig -Path $path -Section "" `
                -Settings ([ordered]@{ "registry" = "https://npm.flatt.tech/" }) `
                -Separator "="
            $first = (Get-Content $path -Raw)

            Apply-ManagedConfig -Path $path -Section "" `
                -Settings ([ordered]@{ "registry" = "https://npm.flatt.tech/" }) `
                -Separator "="
            $second = (Get-Content $path -Raw)

            $first | Should -Be $second
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force
        }
    }

    It "removes file entirely when restore leaves only comments/whitespace" {
        $tmp = New-TempDir
        try {
            $path = Join-Path $tmp ".npmrc"
            Apply-ManagedConfig -Path $path -Section "" `
                -Settings ([ordered]@{ "registry" = "https://npm.flatt.tech/" }) `
                -Separator "="
            Test-Path $path | Should -BeTrue

            Restore-Config -Path $path
            Test-Path $path | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force
        }
    }

    It "deletes legacy format files (Managed by Takumi Guard header without BEGIN block)" {
        $tmp = New-TempDir
        try {
            $path = Join-Path $tmp "legacy.ini"
            @(
                "# Managed by Takumi Guard (intunewin-builder). DO NOT EDIT MANUALLY."
                "[global]"
                "index-url = https://pypi.flatt.tech/simple/"
            ) | Set-Content -LiteralPath $path

            Restore-Config -Path $path
            Test-Path $path | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force
        }
    }

    It "does not touch files we never managed" {
        $tmp = New-TempDir
        try {
            $path = Join-Path $tmp "foreign.ini"
            $content = @("[global]", "index-url = https://corp/")
            Write-FileNoBom -Path $path -Lines $content

            Restore-Config -Path $path
            Test-Path $path | Should -BeTrue
            (Get-Content $path) | Should -Be $content
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force
        }
    }
}

# ---------------------------------------------------------------------------
# Per-PM integration scenarios (公式 takumi-guard-setup-0.4.0.ps1 と同じ
# キー形式 / セクション配置を満たしているかを確認する)
# ---------------------------------------------------------------------------

Describe "pnpm rc + config.yaml split" {
    It "writes registry to rc (INI) without quotes" {
        $tmp = New-TempDir
        try {
            $path = Join-Path $tmp "rc"
            Apply-ManagedConfig -Path $path -Section "" `
                -Settings ([ordered]@{ "registry" = "https://npm.flatt.tech/" }) `
                -Separator "="
            $content = Get-Content $path -Raw
            $content | Should -Match 'registry=https://npm\.flatt\.tech/'
            # YAML 形式の colon は使われていない
            $content | Should -Not -Match 'registry:\s'
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force
        }
    }

    It "writes minimum-release-age to config.yaml without quotes (YAML scalar)" {
        $tmp = New-TempDir
        try {
            $path = Join-Path $tmp "config.yaml"
            Apply-ManagedConfig -Path $path -Section "" `
                -Settings ([ordered]@{ "minimum-release-age" = 4320 }) `
                -Separator ": "
            $content = Get-Content $path -Raw
            $content | Should -Match 'minimum-release-age: 4320'
            # registry は config.yaml には書かれていない (rc 側に分離した)
            $content | Should -Not -Match 'registry:'
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force
        }
    }

    It "preserves existing pnpm-workspace.yaml-style keys when applied to config.yaml" {
        $tmp = New-TempDir
        try {
            $path = Join-Path $tmp "config.yaml"
            @(
                'auto-install-peers: true'
                'minimum-release-age: 60'
                'hooks:'
                '  readPackage: ./hooks.js'
            ) | Set-Content -LiteralPath $path

            Apply-ManagedConfig -Path $path -Section "" `
                -Settings ([ordered]@{ "minimum-release-age" = 4320 }) `
                -Separator ": "

            $content = Get-Content $path -Raw
            # 元の minimum-release-age はコメントアウト
            $content | Should -Match '# \[TakumiGuard-disabled\] minimum-release-age: 60'
            # 我々の値が入っている
            $content | Should -Match 'minimum-release-age: 4320'
            # 他のキーは無傷
            $content | Should -Match 'auto-install-peers: true'
            $content | Should -Match 'hooks:'
            $content | Should -Match '  readPackage: \./hooks\.js'
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force
        }
    }
}

Describe "bun .bunfig.toml" {
    It "writes registry as object { url = `"...`" } (matches official setup-0.4.0)" {
        $tmp = New-TempDir
        try {
            $path = Join-Path $tmp ".bunfig.toml"
            Apply-ManagedConfig -Path $path -Section "install" `
                -Settings ([ordered]@{
                    "registry"          = '{ url = "https://npm.flatt.tech/" }'
                    "minimumReleaseAge" = 259200
                }) -Separator " = "
            $content = Get-Content $path -Raw
            $content | Should -Match '\[install\]'
            $content | Should -Match 'registry = \{ url = "https://npm\.flatt\.tech/" \}'
            $content | Should -Match 'minimumReleaseAge = 259200'
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force
        }
    }

    It "disables existing scalar registry when present (preserves other [install] keys)" {
        $tmp = New-TempDir
        try {
            $path = Join-Path $tmp ".bunfig.toml"
            @(
                '[install]'
                'exact = true'
                'registry = "https://corp.example/"'
                ''
                '[install.cache]'
                'dir = "/tmp/bun"'
            ) | Set-Content -LiteralPath $path

            Apply-ManagedConfig -Path $path -Section "install" `
                -Settings ([ordered]@{
                    "registry"          = '{ url = "https://npm.flatt.tech/" }'
                    "minimumReleaseAge" = 259200
                }) -Separator " = "

            $content = Get-Content $path -Raw
            # ours present
            $content | Should -Match 'registry = \{ url = "https://npm\.flatt\.tech/" \}'
            # corp scalar registry commented out
            $content | Should -Match '# \[TakumiGuard-disabled\] registry = "https://corp\.example/"'
            # other keys preserved
            $content | Should -Match 'exact = true'
            $content | Should -Match '\[install\.cache\]'
            $content | Should -Match 'dir = "/tmp/bun"'
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force
        }
    }
}
