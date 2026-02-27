module Test exposing (run)

import BackendTask exposing (BackendTask)
import BackendTask.Stream
import FatalError exposing (FatalError)
import LamderaDb.FileHelpers exposing (copyFile, deleteDir, deleteFile, fileExists, mkTempDir)
import Pages.Script as Script exposing (Script)


run : Script
run =
    Script.withoutCliOptions
        (mkTempDir
            |> BackendTask.andThen
                (\backupDir ->
                    saveCurrentState backupDir
                        |> BackendTask.andThen (\_ -> runAllPhases backupDir)
                        |> BackendTask.andThen
                            (\_ ->
                                cleanup backupDir
                                    |> BackendTask.andThen (\_ -> Script.log "\n=== All migration tests passed! ===")
                            )
                )
        )



-- File operations helpers


cp : String -> String -> BackendTask FatalError ()
cp from to =
    copyFile { from = from, to = to }


cpIfExists : String -> String -> BackendTask FatalError ()
cpIfExists from to =
    fileExists from
        |> BackendTask.andThen
            (\exists ->
                if exists then
                    cp from to

                else
                    BackendTask.succeed ()
            )


cpDirIfExists : String -> String -> BackendTask FatalError ()
cpDirIfExists from to =
    fileExists from
        |> BackendTask.andThen
            (\exists ->
                if exists then
                    Script.exec "cp" [ "-r", from, to ]

                else
                    BackendTask.succeed ()
            )


rmFile : String -> BackendTask FatalError ()
rmFile =
    deleteFile


rmDir : String -> BackendTask FatalError ()
rmDir =
    deleteDir


elmPagesRun : String -> BackendTask FatalError ()
elmPagesRun scriptPath =
    Script.exec "npx" [ "elm-pages", "run", scriptPath ]


elmPagesRunCapture : String -> BackendTask FatalError { succeeded : Bool, output : String }
elmPagesRunCapture scriptPath =
    BackendTask.Stream.commandWithOptions
        (BackendTask.Stream.defaultCommandOptions
            |> BackendTask.Stream.allowNon0Status
            |> BackendTask.Stream.withOutput BackendTask.Stream.MergeStderrAndStdout
        )
        "npx"
        [ "elm-pages", "run", scriptPath ]
        |> BackendTask.Stream.read
        |> BackendTask.map (\{ body } -> { succeeded = True, output = body })
        |> BackendTask.onError
            (\{ recoverable } ->
                case recoverable of
                    BackendTask.Stream.CustomError _ maybeBody ->
                        BackendTask.succeed { succeeded = False, output = Maybe.withDefault "" maybeBody }

                    BackendTask.Stream.StreamError msg ->
                        BackendTask.succeed { succeeded = False, output = msg }
            )
        |> BackendTask.allowFatal


npmRunMigrate : BackendTask FatalError ()
npmRunMigrate =
    Script.exec "npm" [ "run", "migrate" ]


npmRunMigrateCapture : BackendTask FatalError { succeeded : Bool, output : String }
npmRunMigrateCapture =
    BackendTask.Stream.commandWithOptions
        (BackendTask.Stream.defaultCommandOptions
            |> BackendTask.Stream.allowNon0Status
            |> BackendTask.Stream.withOutput BackendTask.Stream.MergeStderrAndStdout
        )
        "npm"
        [ "run", "migrate" ]
        |> BackendTask.Stream.read
        |> BackendTask.map (\{ body } -> { succeeded = True, output = body })
        |> BackendTask.onError
            (\{ recoverable } ->
                case recoverable of
                    BackendTask.Stream.CustomError _ maybeBody ->
                        BackendTask.succeed { succeeded = False, output = Maybe.withDefault "" maybeBody }

                    BackendTask.Stream.StreamError msg ->
                        BackendTask.succeed { succeeded = False, output = msg }
            )
        |> BackendTask.allowFatal


assertContains : String -> String -> String -> BackendTask FatalError ()
assertContains label needle haystack =
    if String.contains (String.toLower needle) (String.toLower haystack) then
        BackendTask.succeed ()

    else
        BackendTask.fail
            (FatalError.build
                { title = "FAIL: " ++ label
                , body = "Expected output to contain '" ++ needle ++ "'\nGot: " ++ haystack
                }
            )


assertNotContains : String -> String -> String -> BackendTask FatalError ()
assertNotContains label needle haystack =
    if String.contains (String.toLower needle) (String.toLower haystack) then
        BackendTask.fail
            (FatalError.build
                { title = "FAIL: " ++ label
                , body = "Expected output NOT to contain '" ++ needle ++ "'\nGot: " ++ haystack
                }
            )

    else
        BackendTask.succeed ()



-- State management


saveCurrentState : String -> BackendTask FatalError ()
saveCurrentState backupDir =
    cp "src/Types.elm" (backupDir ++ "/Types.elm")
        |> BackendTask.andThen (\_ -> cp "script/SeedDb.elm" (backupDir ++ "/SeedDb.elm"))
        |> BackendTask.andThen (\_ -> cp "script/Example.elm" (backupDir ++ "/Example.elm"))
        |> BackendTask.andThen (\_ -> cp ".lamdera-db/SchemaVersion.elm" (backupDir ++ "/SchemaVersion.elm"))
        |> BackendTask.andThen (\_ -> cpIfExists ".lamdera-db/Migrate.elm" (backupDir ++ "/Migrate.elm"))
        |> BackendTask.andThen (\_ -> cpIfExists ".lamdera-db/MigrateChain.elm" (backupDir ++ "/MigrateChain.elm"))
        |> BackendTask.andThen (\_ -> cpIfExists "script/TestVerifyMigration.elm" (backupDir ++ "/TestVerifyMigration.elm"))
        |> BackendTask.andThen (\_ -> cpDirIfExists "src/Evergreen" (backupDir ++ "/Evergreen"))


restoreV2 : String -> BackendTask FatalError ()
restoreV2 backupDir =
    cp (backupDir ++ "/Types.elm") "src/Types.elm"
        |> BackendTask.andThen (\_ -> cp (backupDir ++ "/SeedDb.elm") "script/SeedDb.elm")
        |> BackendTask.andThen (\_ -> cp (backupDir ++ "/Example.elm") "script/Example.elm")
        |> BackendTask.andThen (\_ -> cp (backupDir ++ "/SchemaVersion.elm") ".lamdera-db/SchemaVersion.elm")
        |> BackendTask.andThen (\_ -> cpIfExists (backupDir ++ "/Migrate.elm") ".lamdera-db/Migrate.elm")
        |> BackendTask.andThen (\_ -> cpIfExists (backupDir ++ "/MigrateChain.elm") ".lamdera-db/MigrateChain.elm")
        |> BackendTask.andThen (\_ -> cpIfExists (backupDir ++ "/TestVerifyMigration.elm") "script/TestVerifyMigration.elm")
        |> BackendTask.andThen
            (\_ ->
                fileExists (backupDir ++ "/Evergreen")
                    |> BackendTask.andThen
                        (\exists ->
                            if exists then
                                rmDir "src/Evergreen"
                                    |> BackendTask.andThen (\_ -> Script.exec "cp" [ "-r", backupDir ++ "/Evergreen", "src/Evergreen" ])

                            else
                                BackendTask.succeed ()
                        )
            )


cleanup : String -> BackendTask FatalError ()
cleanup backupDir =
    restoreV2 backupDir
        |> BackendTask.andThen (\_ -> rmFile "db.bin")
        |> BackendTask.andThen (\_ -> rmFile "db.bin.backup")
        |> BackendTask.andThen (\_ -> rmFile "db.lock")
        |> BackendTask.andThen (\_ -> rmFile "script/TestVerifyV3.elm")
        |> BackendTask.andThen (\_ -> rmFile ".lamdera-db/LamderaDbDeepCheckTmpTypes.elm")
        |> BackendTask.andThen (\_ -> rmFile ".lamdera-db/LamderaDbDeepCheckTmpWitness.elm")
        |> BackendTask.andThen (\_ -> rmDir backupDir)


setupV1 : BackendTask FatalError ()
setupV1 =
    cp "test/fixtures/v1/Types.elm" "src/Types.elm"
        |> BackendTask.andThen (\_ -> cp "test/fixtures/v1/SeedDb.elm" "script/SeedDb.elm")
        |> BackendTask.andThen (\_ -> cp "test/fixtures/v1/Example.elm" "script/Example.elm")
        |> BackendTask.andThen (\_ -> cp "test/fixtures/v1/SchemaVersion.elm" ".lamdera-db/SchemaVersion.elm")
        |> BackendTask.andThen (\_ -> cp "test/fixtures/v1/Migrate.elm" ".lamdera-db/Migrate.elm")
        |> BackendTask.andThen (\_ -> rmFile ".lamdera-db/MigrateChain.elm")
        |> BackendTask.andThen (\_ -> rmFile "script/TestVerifyMigration.elm")
        |> BackendTask.andThen (\_ -> rmDir "src/Evergreen")
        |> BackendTask.andThen (\_ -> rmFile "db.bin")



-- All test phases


runAllPhases : String -> BackendTask FatalError ()
runAllPhases backupDir =
    phase1 backupDir
        |> BackendTask.andThen (\_ -> phase1b)
        |> BackendTask.andThen (\_ -> phase2 backupDir)
        |> BackendTask.andThen (\_ -> phase3)
        |> BackendTask.andThen (\_ -> phase4)
        |> BackendTask.andThen (\_ -> phase4b backupDir)
        |> BackendTask.andThen (\_ -> phase4c backupDir)
        |> BackendTask.andThen (\_ -> phase4d backupDir)
        |> BackendTask.andThen (\_ -> phase4e backupDir)
        |> BackendTask.andThen (\_ -> phase4f backupDir)
        |> BackendTask.andThen (\_ -> phase4g backupDir)
        |> BackendTask.andThen (\_ -> phase4h backupDir)
        |> BackendTask.andThen (\_ -> phase4i backupDir)
        |> BackendTask.andThen (\_ -> phase5 backupDir)
        |> BackendTask.andThen (\_ -> phase5b backupDir)
        |> BackendTask.andThen (\_ -> phase6 backupDir)
        |> BackendTask.andThen (\_ -> phase7 backupDir)



-- Phase 1: V1 environment


phase1 : String -> BackendTask FatalError ()
phase1 _ =
    setupV1
        |> BackendTask.andThen (\_ -> elmPagesRun "script/SeedDb.elm")
        |> BackendTask.andThen (\_ -> Script.log "✓ Phase 1: Seeded V1 data")
        |> BackendTask.andThen (\_ -> elmPagesRun "script/MigrationTest.elm")
        |> BackendTask.andThen (\_ -> Script.log "✓ Phase 1: V1 data reads OK")



-- Phase 1b: Reject modified types without version bump


phase1b : BackendTask FatalError ()
phase1b =
    cp "test/fixtures/v1-modified/Types.elm" "src/Types.elm"
        |> BackendTask.andThen (\_ -> cp "test/fixtures/v1-modified/SeedDb.elm" "script/SeedDb.elm")
        |> BackendTask.andThen (\_ -> cp "test/fixtures/v1-modified/Example.elm" "script/Example.elm")
        |> BackendTask.andThen (\_ -> elmPagesRunCapture "script/MigrationTest.elm")
        |> BackendTask.andThen
            (\{ output } ->
                assertNotContains "Should have rejected db.bin after Types.elm changed without version bump" "BackendModel loaded" output
            )
        |> BackendTask.andThen (\_ -> Script.log "✓ Phase 1b: Schema change without version bump correctly rejected")
        |> BackendTask.andThen (\_ -> cp "test/fixtures/v1/Types.elm" "src/Types.elm")
        |> BackendTask.andThen (\_ -> cp "test/fixtures/v1/SeedDb.elm" "script/SeedDb.elm")
        |> BackendTask.andThen (\_ -> cp "test/fixtures/v1/Example.elm" "script/Example.elm")



-- Phase 2: V2 schema rejects V1 data


phase2 : String -> BackendTask FatalError ()
phase2 backupDir =
    restoreV2 backupDir
        |> BackendTask.andThen (\_ -> elmPagesRunCapture "script/MigrationTest.elm")
        |> BackendTask.andThen
            (\{ output } ->
                assertContains "Expected 'Schema version mismatch'" "schema version mismatch" output
            )
        |> BackendTask.andThen (\_ -> Script.log "✓ Phase 2: V1 data correctly rejected by V2 schema")



-- Phase 3: Run migration


phase3 : BackendTask FatalError ()
phase3 =
    npmRunMigrate
        |> BackendTask.andThen (\_ -> Script.log "✓ Phase 3: Migration completed")



-- Phase 4: Verify migrated data


phase4 : BackendTask FatalError ()
phase4 =
    elmPagesRun "script/TestVerifyMigration.elm"
        |> BackendTask.andThen (\_ -> Script.log "✓ Phase 4: Migrated data verified — all values correct")



-- Phase 4b: V2 types modified without version bump


phase4b : String -> BackendTask FatalError ()
phase4b backupDir =
    restoreV2 backupDir
        |> BackendTask.andThen (\_ -> elmPagesRun "script/SeedDb.elm")
        |> BackendTask.andThen (\_ -> cp "test/fixtures/v2-modified/Types.elm" "src/Types.elm")
        |> BackendTask.andThen (\_ -> cp "test/fixtures/v2-modified/SeedDb.elm" "script/SeedDb.elm")
        |> BackendTask.andThen (\_ -> cp "test/fixtures/v2-modified/Example.elm" "script/Example.elm")
        |> BackendTask.andThen (\_ -> rmFile "script/TestVerifyMigration.elm")
        |> BackendTask.andThen (\_ -> rmDir "src/Evergreen")
        |> BackendTask.andThen (\_ -> elmPagesRunCapture "script/MigrationTest.elm")
        |> BackendTask.andThen
            (\{ output } ->
                assertNotContains "Should have rejected db.bin after V2 Types.elm changed without version bump" "BackendModel loaded" output
            )
        |> BackendTask.andThen (\_ -> Script.log "✓ Phase 4b: V2 schema change without version bump correctly rejected")



-- Phase 4c: Comment-only change allowed


phase4c : String -> BackendTask FatalError ()
phase4c backupDir =
    restoreV2 backupDir
        |> BackendTask.andThen (\_ -> rmFile "db.bin")
        |> BackendTask.andThen (\_ -> elmPagesRun "script/SeedDb.elm")
        |> BackendTask.andThen (\_ -> cp "test/fixtures/v2-comment-only/Types.elm" "src/Types.elm")
        |> BackendTask.andThen (\_ -> elmPagesRunCapture "script/MigrationTest.elm")
        |> BackendTask.andThen
            (\{ output } ->
                assertContains "Comment-only Types.elm change should have been allowed" "BackendModel loaded" output
            )
        |> BackendTask.andThen (\_ -> Script.log "✓ Phase 4c: Comment-only Types.elm change correctly allowed (first run)")
        |> BackendTask.andThen (\_ -> elmPagesRunCapture "script/MigrationTest.elm")
        |> BackendTask.andThen
            (\{ output } ->
                assertContains "Second run after comment-only change should have succeeded" "BackendModel loaded" output
            )
        |> BackendTask.andThen (\_ -> Script.log "✓ Phase 4c: Second run hit fast path — fingerprint update verified")
        |> BackendTask.andThen (\_ -> restoreV2 backupDir)



-- Phase 4d: Non-BackendModel type change allowed


phase4d : String -> BackendTask FatalError ()
phase4d backupDir =
    rmFile "db.bin"
        |> BackendTask.andThen (\_ -> elmPagesRun "script/SeedDb.elm")
        |> BackendTask.andThen (\_ -> cp "test/fixtures/v2-non-backend-change/Types.elm" "src/Types.elm")
        |> BackendTask.andThen (\_ -> elmPagesRunCapture "script/MigrationTest.elm")
        |> BackendTask.andThen
            (\{ output } ->
                assertContains "Non-BackendModel Types.elm change should have been allowed" "BackendModel loaded" output
            )
        |> BackendTask.andThen (\_ -> Script.log "✓ Phase 4d: Non-BackendModel Types.elm change correctly allowed")
        |> BackendTask.andThen (\_ -> restoreV2 backupDir)



-- Phase 4e: Declaration reorder allowed


phase4e : String -> BackendTask FatalError ()
phase4e backupDir =
    restoreV2 backupDir
        |> BackendTask.andThen (\_ -> rmFile "db.bin")
        |> BackendTask.andThen (\_ -> elmPagesRun "script/SeedDb.elm")
        |> BackendTask.andThen (\_ -> cp "test/fixtures/v2-declaration-reorder/Types.elm" "src/Types.elm")
        |> BackendTask.andThen (\_ -> elmPagesRunCapture "script/MigrationTest.elm")
        |> BackendTask.andThen
            (\{ output } ->
                assertContains "Declaration-reorder Types.elm change should have been allowed" "BackendModel loaded" output
            )
        |> BackendTask.andThen (\_ -> Script.log "✓ Phase 4e: Declaration reorder correctly allowed")
        |> BackendTask.andThen (\_ -> restoreV2 backupDir)



-- Phase 4f: Legacy envelope without `t` field


phase4f : String -> BackendTask FatalError ()
phase4f backupDir =
    restoreV2 backupDir
        |> BackendTask.andThen (\_ -> rmFile "db.bin")
        |> BackendTask.andThen (\_ -> elmPagesRun "script/SeedDb.elm")
        |> BackendTask.andThen
            (\_ ->
                Script.exec "node"
                    [ "-e"
                    , "const fs = require('fs'); const j = JSON.parse(fs.readFileSync('db.bin','utf8')); delete j.t; fs.writeFileSync('db.bin', JSON.stringify(j));"
                    ]
            )
        |> BackendTask.andThen (\_ -> elmPagesRunCapture "script/MigrationTest.elm")
        |> BackendTask.andThen
            (\{ output } ->
                assertContains "Legacy envelope without t field should still load" "BackendModel loaded" output
            )
        |> BackendTask.andThen (\_ -> Script.log "✓ Phase 4f: Legacy envelope without t field correctly handled")
        |> BackendTask.andThen (\_ -> restoreV2 backupDir)



-- Phase 4g: Deep comparator failure → fail closed


phase4g : String -> BackendTask FatalError ()
phase4g backupDir =
    restoreV2 backupDir
        |> BackendTask.andThen (\_ -> rmFile "db.bin")
        |> BackendTask.andThen (\_ -> elmPagesRun "script/SeedDb.elm")
        |> BackendTask.andThen
            (\_ ->
                Script.exec "node"
                    [ "-e"
                    , "const fs = require('fs'); const j = JSON.parse(fs.readFileSync('db.bin','utf8')); j.t = 'invalid_elm_source_that_cannot_compile'; fs.writeFileSync('db.bin', JSON.stringify(j));"
                    ]
            )
        |> BackendTask.andThen (\_ -> elmPagesRunCapture "script/MigrationTest.elm")
        |> BackendTask.andThen
            (\{ output } ->
                assertContains "Deep check failure should report schema compatibility error" "could not verify schema compatibility" output
                    |> BackendTask.andThen
                        (\_ ->
                            assertNotContains "Deep check failure should not load model" "BackendModel loaded" output
                        )
            )
        |> BackendTask.andThen (\_ -> Script.log "✓ Phase 4g: Deep comparator failure correctly fails closed")
        |> BackendTask.andThen (\_ -> restoreV2 backupDir)



-- Phase 4h: Corrupt db.bin envelope


phase4h : String -> BackendTask FatalError ()
phase4h backupDir =
    restoreV2 backupDir
        |> BackendTask.andThen (\_ -> rmFile "db.bin")
        |> BackendTask.andThen (\_ -> elmPagesRun "script/SeedDb.elm")
        |> BackendTask.andThen
            (\_ ->
                Script.exec "node"
                    [ "-e"
                    , "require('fs').writeFileSync('db.bin', 'this is not valid json!!!');"
                    ]
            )
        |> BackendTask.andThen (\_ -> elmPagesRunCapture "script/MigrationTest.elm")
        |> BackendTask.andThen
            (\{ output } ->
                assertContains "Corrupt db.bin should report decode error" "decode" output
                    |> BackendTask.andThen (\_ -> assertNotContains "Corrupt db.bin should not load model" "BackendModel loaded" output)
            )
        |> BackendTask.andThen (\_ -> Script.log "✓ Phase 4h: Corrupt db.bin correctly produces decode error")
        |> BackendTask.andThen (\_ -> restoreV2 backupDir)



-- Phase 4i: get returns initialBackendModel when no db.bin


phase4i : String -> BackendTask FatalError ()
phase4i backupDir =
    restoreV2 backupDir
        |> BackendTask.andThen (\_ -> rmFile "db.bin")
        |> BackendTask.andThen (\_ -> elmPagesRunCapture "script/MigrationTest.elm")
        |> BackendTask.andThen
            (\{ output } ->
                assertContains "No db.bin should return initialBackendModel" "todos: 0" output
                    |> BackendTask.andThen (\_ -> assertContains "No db.bin should return initialBackendModel" "nextId: 1" output)
            )
        |> BackendTask.andThen (\_ -> Script.log "✓ Phase 4i: No db.bin correctly returns initialBackendModel (todos: 0, nextId: 1)")
        |> BackendTask.andThen (\_ -> restoreV2 backupDir)



-- Phase 5: V2→V3 migration


phase5 : String -> BackendTask FatalError ()
phase5 backupDir =
    restoreV2 backupDir
        |> BackendTask.andThen (\_ -> rmFile "db.bin")
        |> BackendTask.andThen (\_ -> elmPagesRun "script/SeedDb.elm")
        |> BackendTask.andThen (\_ -> Script.log "✓ Phase 5: Seeded clean V2 data")
        |> BackendTask.andThen (\_ -> cp "test/fixtures/v3/Types.elm" "src/Types.elm")
        |> BackendTask.andThen (\_ -> cp "test/fixtures/v3/SeedDb.elm" "script/SeedDb.elm")
        |> BackendTask.andThen (\_ -> cp "test/fixtures/v3/Example.elm" "script/Example.elm")
        |> BackendTask.andThen (\_ -> npmRunMigrate)
        |> BackendTask.andThen (\_ -> Script.log "✓ Phase 5: Auto-snapshot V2→V3 completed")
        |> BackendTask.andThen (\_ -> cp "test/fixtures/v3/MigrateV3.elm" "src/Evergreen/Migrate/V3.elm")
        |> BackendTask.andThen (\_ -> cp "test/fixtures/v3/TestVerifyV3.elm" "script/TestVerifyV3.elm")
        |> BackendTask.andThen (\_ -> npmRunMigrate)
        |> BackendTask.andThen (\_ -> Script.log "✓ Phase 5: V2→V3 migration completed")
        |> BackendTask.andThen
            (\_ ->
                fileExists "db.bin.backup"
                    |> BackendTask.andThen
                        (\exists ->
                            if exists then
                                Script.log "✓ Phase 5: db.bin.backup created"

                            else
                                BackendTask.fail
                                    (FatalError.build
                                        { title = "FAIL"
                                        , body = "db.bin.backup should have been created before migration"
                                        }
                                    )
                        )
            )
        |> BackendTask.andThen (\_ -> elmPagesRun "script/TestVerifyV3.elm")
        |> BackendTask.andThen (\_ -> Script.log "✓ Phase 5: V3 data verified — all values correct")



-- Phase 5b: V1→V2→V3 chaining


phase5b : String -> BackendTask FatalError ()
phase5b backupDir =
    mkTempDir
        |> BackendTask.andThen
            (\v3Backup ->
                -- Save V3 state
                cp "src/Types.elm" (v3Backup ++ "/Types.elm")
                    |> BackendTask.andThen (\_ -> cp "script/SeedDb.elm" (v3Backup ++ "/SeedDb.elm"))
                    |> BackendTask.andThen (\_ -> cp "script/Example.elm" (v3Backup ++ "/Example.elm"))
                    |> BackendTask.andThen (\_ -> cp ".lamdera-db/SchemaVersion.elm" (v3Backup ++ "/SchemaVersion.elm"))
                    |> BackendTask.andThen (\_ -> cp ".lamdera-db/Migrate.elm" (v3Backup ++ "/Migrate.elm"))
                    |> BackendTask.andThen (\_ -> cp ".lamdera-db/MigrateChain.elm" (v3Backup ++ "/MigrateChain.elm"))
                    |> BackendTask.andThen (\_ -> Script.exec "cp" [ "-r", "src/Evergreen", v3Backup ++ "/Evergreen" ])
                    -- Switch to V1 to seed V1 data
                    |> BackendTask.andThen (\_ -> setupV1)
                    |> BackendTask.andThen (\_ -> elmPagesRun "script/SeedDb.elm")
                    |> BackendTask.andThen (\_ -> Script.log "✓ Phase 5b: Re-seeded V1 data")
                    -- Restore V3 state (keeping V1 db.bin)
                    |> BackendTask.andThen (\_ -> cp (v3Backup ++ "/Types.elm") "src/Types.elm")
                    |> BackendTask.andThen (\_ -> cp (v3Backup ++ "/SeedDb.elm") "script/SeedDb.elm")
                    |> BackendTask.andThen (\_ -> cp (v3Backup ++ "/Example.elm") "script/Example.elm")
                    |> BackendTask.andThen (\_ -> cp (v3Backup ++ "/SchemaVersion.elm") ".lamdera-db/SchemaVersion.elm")
                    |> BackendTask.andThen (\_ -> cp (v3Backup ++ "/Migrate.elm") ".lamdera-db/Migrate.elm")
                    |> BackendTask.andThen (\_ -> cp (v3Backup ++ "/MigrateChain.elm") ".lamdera-db/MigrateChain.elm")
                    |> BackendTask.andThen (\_ -> rmDir "src/Evergreen")
                    |> BackendTask.andThen (\_ -> Script.exec "cp" [ "-r", v3Backup ++ "/Evergreen", "src/Evergreen" ])
                    |> BackendTask.andThen (\_ -> rmDir v3Backup)
                    -- Run migration — should chain V1→V2→V3
                    |> BackendTask.andThen (\_ -> npmRunMigrate)
                    |> BackendTask.andThen (\_ -> Script.log "✓ Phase 5b: V1→V2→V3 chaining migration completed")
                    |> BackendTask.andThen (\_ -> elmPagesRun "script/TestVerifyV3.elm")
                    |> BackendTask.andThen (\_ -> Script.log "✓ Phase 5b: V1→V3 chained migration verified — all values correct")
            )



-- Phase 6: Auto-snapshot after Types.elm change (natural workflow)


phase6 : String -> BackendTask FatalError ()
phase6 backupDir =
    setupV1
        |> BackendTask.andThen (\_ -> rmFile "script/TestVerifyV3.elm")
        |> BackendTask.andThen (\_ -> elmPagesRun "script/SeedDb.elm")
        |> BackendTask.andThen (\_ -> Script.log "✓ Phase 6: Seeded V1 data")
        -- User changes Types.elm to V2 BEFORE running migrate
        |> BackendTask.andThen (\_ -> cp (backupDir ++ "/Types.elm") "src/Types.elm")
        |> BackendTask.andThen (\_ -> cp (backupDir ++ "/SeedDb.elm") "script/SeedDb.elm")
        |> BackendTask.andThen (\_ -> cp (backupDir ++ "/Example.elm") "script/Example.elm")
        -- Run migrate — auto-snapshot
        |> BackendTask.andThen (\_ -> npmRunMigrate)
        |> BackendTask.andThen (\_ -> Script.log "✓ Phase 6: Auto-snapshot completed after Types.elm change")
        -- Install real V2 migration
        |> BackendTask.andThen (\_ -> cp (backupDir ++ "/Evergreen/Migrate/V2.elm") "src/Evergreen/Migrate/V2.elm")
        -- Run migration
        |> BackendTask.andThen (\_ -> npmRunMigrateCapture)
        |> BackendTask.andThen
            (\{ output } ->
                assertContains "Auto-snapshot after Types.elm change should produce working migration" "migrated db.bin to version" output
                    |> BackendTask.andThen (\_ -> Script.log "✓ Phase 6: V1→V2 migration completed (natural workflow)")
            )
        -- Verify
        |> BackendTask.andThen (\_ -> elmPagesRunCapture "script/MigrationTest.elm")
        |> BackendTask.andThen
            (\{ output } ->
                assertContains "Could not read data after natural-workflow migration" "BackendModel loaded" output
                    |> BackendTask.andThen (\_ -> Script.log "✓ Phase 6: Migrated data verified — natural workflow works correctly")
            )



-- Phase 7: Double migrate guard


phase7 : String -> BackendTask FatalError ()
phase7 backupDir =
    setupV1
        |> BackendTask.andThen (\_ -> rmFile "script/TestVerifyV3.elm")
        |> BackendTask.andThen (\_ -> elmPagesRun "script/SeedDb.elm")
        |> BackendTask.andThen (\_ -> Script.log "✓ Phase 7: Seeded V1 data")
        -- Change to V2 types
        |> BackendTask.andThen (\_ -> cp (backupDir ++ "/Types.elm") "src/Types.elm")
        |> BackendTask.andThen (\_ -> cp (backupDir ++ "/SeedDb.elm") "script/SeedDb.elm")
        |> BackendTask.andThen (\_ -> cp (backupDir ++ "/Example.elm") "script/Example.elm")
        -- First migrate (auto-snapshot)
        |> BackendTask.andThen (\_ -> npmRunMigrate)
        |> BackendTask.andThen (\_ -> Script.log "✓ Phase 7: First migrate (auto-snapshot) succeeded")
        -- Second migrate without implementing stub — should fail
        |> BackendTask.andThen (\_ -> npmRunMigrateCapture)
        |> BackendTask.andThen
            (\{ output } ->
                assertContains "Running migrate without implementing stub should produce compile error" "todo_implementMigration" output
                    |> BackendTask.andThen (\_ -> Script.log "✓ Phase 7: Second migrate correctly blocked by compile-error sentinel")
            )
        |> BackendTask.andThen (\_ -> rmFile "db.bin")
        |> BackendTask.andThen (\_ -> rmFile "db.bin.backup")
