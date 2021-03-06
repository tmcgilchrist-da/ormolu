{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

module Main (main) where

import Control.Exception (SomeException, displayException, try)
import Control.Monad
import Data.Bool (bool)
import Data.Either (lefts)
import Data.List (intercalate, sort)
import qualified Data.Text.IO as TIO
import Data.Version (showVersion)
import Development.GitRev
import Options.Applicative
import Ormolu
import Ormolu.Parser (manualExts)
import Ormolu.Utils (showOutputable)
import Paths_ormolu (version)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

-- | Entry point of the program.
main :: IO ()
main = withPrettyOrmoluExceptions $ do
  Opts {..} <- execParser optsParserInfo
  let formatOne' = formatOne optMode optConfig
  case optInputFiles of
    [] -> formatOne' Nothing
    ["-"] -> formatOne' Nothing
    [x] -> formatOne' (Just x)
    xs -> do
      -- It is possible to get IOException, error's and 'OrmoluException's
      -- from 'formatOne', so we just catch everything.
      errs <-
        lefts <$> mapM (try @SomeException . formatOne' . Just) (sort xs)
      unless (null errs) $ do
        mapM_ (hPutStrLn stderr . displayException) errs
        exitWith (ExitFailure 102)

-- | Format a single input.
formatOne ::
  -- | Mode of operation
  Mode ->
  -- | Configuration
  Config RegionIndices ->
  -- | File to format or stdin as 'Nothing'
  Maybe FilePath ->
  IO ()
formatOne mode config = \case
  Nothing -> do
    r <- ormoluStdin config
    case mode of
      Stdout -> TIO.putStr r
      _ -> do
        hPutStrLn
          stderr
          "This feature is not supported when input comes from stdin."
        -- 101 is different from all the other exit codes we already use.
        exitWith (ExitFailure 101)
  Just inputFile -> do
    originalInput <- TIO.readFile inputFile
    formattedInput <- ormoluFile config inputFile
    case mode of
      Stdout ->
        TIO.putStr formattedInput
      InPlace -> do
        -- Only write when the contents have changed, in order to avoid
        -- updating the modified timestamp if the file was already correctly
        -- formatted.
        when (formattedInput /= originalInput) $
          TIO.writeFile inputFile formattedInput
      Check -> do
        when (formattedInput /= originalInput) $
          -- 100 is different to all the other exit code that are emitted
          -- either from an 'OrmoluException' or from 'error' and
          -- 'notImplemented'.
          exitWith (ExitFailure 100)

----------------------------------------------------------------------------
-- Command line options parsing.

data Opts = Opts
  { -- | Mode of operation
    optMode :: !Mode,
    -- | Ormolu 'Config'
    optConfig :: !(Config RegionIndices),
    -- | Haskell source files to format or stdin (when the list is empty)
    optInputFiles :: ![FilePath]
  }

-- | Mode of operation.
data Mode
  = -- | Output formatted source code to stdout
    Stdout
  | -- | Overwrite original file
    InPlace
  | -- | Exit with non-zero status code if
    -- source is not already formatted
    Check
  deriving (Eq, Show)

optsParserInfo :: ParserInfo Opts
optsParserInfo =
  info (helper <*> ver <*> exts <*> optsParser) . mconcat $
    [ fullDesc,
      progDesc "",
      header ""
    ]
  where
    ver :: Parser (a -> a)
    ver =
      infoOption verStr . mconcat $
        [ long "version",
          short 'v',
          help "Print version of the program"
        ]
    verStr =
      intercalate
        "\n"
        [ unwords
            [ "ormolu",
              showVersion version,
              $gitBranch,
              $gitHash
            ],
          "using ghc-lib-parser " ++ VERSION_ghc_lib_parser
        ]
    exts :: Parser (a -> a)
    exts =
      infoOption displayExts . mconcat $
        [ long "manual-exts",
          help "Display extensions that need to be enabled manually"
        ]
    displayExts = unlines $ sort (showOutputable <$> manualExts)

optsParser :: Parser Opts
optsParser =
  Opts
    <$> ( (fmap (bool Stdout InPlace) . switch . mconcat)
            [ short 'i',
              help "A shortcut for --mode inplace"
            ]
            <|> (option parseMode . mconcat)
              [ long "mode",
                short 'm',
                metavar "MODE",
                value Stdout,
                help "Mode of operation: 'stdout' (default), 'inplace', or 'check'"
              ]
        )
    <*> configParser
    <*> (many . strArgument . mconcat)
      [ metavar "FILE",
        help "Haskell source files to format or stdin (default)"
      ]

configParser :: Parser (Config RegionIndices)
configParser =
  Config
    <$> (fmap (fmap DynOption) . many . strOption . mconcat)
      [ long "ghc-opt",
        short 'o',
        metavar "OPT",
        help "GHC options to enable (e.g. language extensions)"
      ]
    <*> (switch . mconcat)
      [ long "unsafe",
        short 'u',
        help "Do formatting faster but without automatic detection of defects"
      ]
    <*> (switch . mconcat)
      [ long "debug",
        short 'd',
        help "Output information useful for debugging"
      ]
    <*> (switch . mconcat)
      [ long "check-idempotence",
        short 'c',
        help "Fail if formatting is not idempotent"
      ]
    <*> ( RegionIndices
            <$> (optional . option auto . mconcat)
              [ long "start-line",
                metavar "START",
                help "Start line of the region to format (starts from 1)"
              ]
            <*> (optional . option auto . mconcat)
              [ long "end-line",
                metavar "END",
                help "End line of the region to format (inclusive)"
              ]
        )

----------------------------------------------------------------------------
-- Helpers

-- | Parse 'Mode'.
parseMode :: ReadM Mode
parseMode = eitherReader $ \case
  "stdout" -> Right Stdout
  "inplace" -> Right InPlace
  "check" -> Right Check
  s -> Left $ "unknown mode: " ++ s
