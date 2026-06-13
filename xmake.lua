-- add modes: debug and release
add_rules("mode.debug", "mode.release")

-- Note: Configure with `xmake f --target_minver=13.0` before building
-- to set the macOS deployment target properly.

-- add target
target("minttab")
    -- set kind
    set_kind("binary")

    -- add files
    add_files("src/*.swift", "src/*.c")

    -- add frameworks for macOS
    add_frameworks("AppKit", "Carbon")

    -- ad-hoc sign after build to avoid exec errors
    after_build(function (target)
        os.exec("codesign --force --sign - " .. target:targetfile())
    end)
