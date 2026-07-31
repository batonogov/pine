on run arguments
    if (count of arguments) is not 2 then
        error "Expected the mounted disk name and mount path"
    end if

    set diskName to item 1 of arguments

    tell application "Finder"
        tell disk diskName
            open

            tell container window
                set current view to icon view
                set toolbar visible to false
                set statusbar visible to false
                set bounds to {120, 100, 780, 520}
            end tell

            set viewOptions to icon view options of container window
            tell viewOptions
                set arrangement to not arranged
                set icon size to 128
                set text size to 15
            end tell
            set background picture of viewOptions to file ".background:background@2x.png"

            set position of item "Pine.app" to {170, 210}
            set position of item "Applications" to {490, 210}

            close
            open
            delay 1

            -- Toggling the bounds makes Finder persist the exact window size.
            tell container window
                set bounds to {120, 100, 779, 519}
            end tell
            delay 1
            tell container window
                set bounds to {120, 100, 780, 520}
                set toolbar visible to false
                set statusbar visible to false
            end tell

            -- Closing commits the current icon-view state before ejection.
            close
            delay 2
        end tell

        -- APFS-backed images on macOS 27 flush folder metadata at eject.
        eject disk diskName
    end tell
end run
