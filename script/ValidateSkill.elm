module ValidateSkill exposing (run)

import BackendTask exposing (BackendTask)
import BackendTask.File
import Char
import Cli.Option
import Cli.OptionsParser
import Cli.Program
import FatalError exposing (FatalError)
import Json.Decode as Decode
import Pages.Script as Script exposing (Script)
import String


type alias SkillFrontmatter =
    { name : String
    , description : String
    }


run : Script
run =
    Script.withCliOptions
        (Cli.Program.config
            |> Cli.Program.add
                (Cli.OptionsParser.build identity
                    |> Cli.OptionsParser.withOptionalPositionalArg
                        (Cli.Option.optionalPositionalArg "skill-name")
                )
        )
        (\maybeName ->
            validateSkill (Maybe.withDefault "evergreen-migration-assist" maybeName)
        )


validateSkill : String -> BackendTask FatalError ()
validateSkill skillName =
    let
        skillDir =
            "skills/" ++ skillName

        skillMdPath =
            skillDir ++ "/SKILL.md"

        openAiYamlPath =
            skillDir ++ "/agents/openai.yaml"
    in
    BackendTask.File.onlyFrontmatter frontmatterDecoder skillMdPath
        |> BackendTask.allowFatal
        |> BackendTask.andThen (validateFrontmatter skillName)
        |> BackendTask.andThen
            (\_ ->
                BackendTask.File.rawFile openAiYamlPath
                    |> BackendTask.allowFatal
                    |> BackendTask.map (\_ -> ())
            )
        |> BackendTask.andThen
            (\_ ->
                Script.log ("Skill validation passed for " ++ skillDir)
            )


validateFrontmatter : String -> SkillFrontmatter -> BackendTask FatalError ()
validateFrontmatter expectedSkillName frontmatter =
    if frontmatter.name /= expectedSkillName then
        fail
            "Skill name mismatch"
            ("Expected frontmatter name `" ++ expectedSkillName ++ "` but found `" ++ frontmatter.name ++ "`.")

    else if not (isValidSkillName frontmatter.name) then
        fail
            "Invalid skill name"
            "Skill name must be lowercase letters, digits, and hyphens only."

    else if String.trim frontmatter.description == "" then
        fail
            "Missing description"
            "SKILL.md frontmatter `description` must be non-empty."

    else
        BackendTask.succeed ()


frontmatterDecoder : Decode.Decoder SkillFrontmatter
frontmatterDecoder =
    Decode.map2 SkillFrontmatter
        (Decode.field "name" Decode.string)
        (Decode.field "description" Decode.string)


isValidSkillName : String -> Bool
isValidSkillName skillName =
    (not (String.isEmpty skillName))
        && String.all
            (\char ->
                Char.isLower char || Char.isDigit char || char == '-'
            )
            skillName


fail : String -> String -> BackendTask FatalError a
fail title body =
    BackendTask.fail (FatalError.build { title = title, body = body })
