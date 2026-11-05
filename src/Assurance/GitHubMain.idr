-- SPDX-License-Identifier: MPL-2.0
module Assurance.GitHubMain

import Assurance.GitHub
import Assurance.Verdict
import Language.JSON
import System
import System.File

%default total

covering
unknown : IO ()
unknown = do
  putStrLn "UNKNOWN"
  exitWith (ExitFailure 2)

covering
run : String -> String -> IO ()
run mode path = do
  input <- readFile path
  case input of
    Left _ => unknown
    Right raw =>
      case strictJSON raw of
        Nothing => unknown
        Just value =>
          case mode of
            "validate" => putStrLn "VALID_JSON"
            "decide" =>
              case wireObservations value of
                Nothing => unknown
                Just observations =>
                  case decide observations of
                    Passed => putStrLn "PASSED"
                    Blocked => do
                      putStrLn "BLOCKED"
                      exitWith (ExitFailure 1)
            _ => unknown

covering
main : IO ()
main = do
  args <- getArgs
  case args of
    [_, mode, path] => run mode path
    _ => unknown
