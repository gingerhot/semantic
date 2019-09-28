{-# LANGUAGE GADTs, TypeOperators, DerivingStrategies #-}
module Semantic.Api.Symbols
  ( legacyParseSymbols
  , parseSymbols
  , parseSymbolsBuilder
  ) where

import           Control.Effect.Error
import           Control.Exception
import           Control.Lens
import           Data.Blob hiding (File (..))
import           Data.ByteString.Builder
import           Data.Maybe
import           Data.Term
import qualified Data.Text as T
import qualified Data.Vector as V
import           Data.Text (pack)
import           Parsing.Parser
import           Prologue
import           Semantic.Api.Bridge
import qualified Semantic.Api.LegacyTypes as Legacy
import           Semantic.Api.Terms (ParseEffects, doParse)
import           Semantic.Proto.SemanticPB hiding (Blob)
import           Semantic.Task
import           Serializing.Format
import           Source.Loc
import           Tags.Taggable
import           Tags.Tagging

legacyParseSymbols :: (Member Distribute sig, ParseEffects sig m, Traversable t) => t Blob -> m Legacy.ParseTreeSymbolResponse
legacyParseSymbols blobs = Legacy.ParseTreeSymbolResponse <$> distributeFoldMap go blobs
  where
    go :: (Member (Error SomeException) sig, Member Task sig, Carrier sig m) => Blob -> m [Legacy.File]
    go blob@Blob{..} = (doParse blob >>= withSomeTerm renderToSymbols) `catchError` (\(SomeException _) -> pure (pure emptyFile))
      where
        emptyFile = tagsToFile []

        -- Legacy symbols output doesn't include Function Calls.
        symbolsToSummarize :: [Text]
        symbolsToSummarize = ["Function", "Method", "Class", "Module"]

        renderToSymbols :: (IsTaggable f, Applicative m) => Term f Loc -> m [Legacy.File]
        renderToSymbols = pure . pure . tagsToFile . runTagging blob symbolsToSummarize

        tagsToFile :: [Tag] -> Legacy.File
        tagsToFile tags = Legacy.File (pack (blobPath blob)) (pack (show (blobLanguage blob))) (fmap tagToSymbol tags)

        tagToSymbol :: Tag -> Legacy.Symbol
        tagToSymbol Tag{..}
          = Legacy.Symbol
          { symbolName = name
          , symbolKind = kind
          , symbolLine = fromMaybe mempty line
          , symbolSpan = converting #? span
          }

parseSymbolsBuilder :: (Member Distribute sig, ParseEffects sig m, Traversable t) => Format ParseTreeSymbolResponse -> t Blob -> m Builder
parseSymbolsBuilder format blobs = parseSymbols blobs >>= serialize format

parseSymbols :: (Member Distribute sig, ParseEffects sig m, Traversable t) => t Blob -> m ParseTreeSymbolResponse
parseSymbols blobs = ParseTreeSymbolResponse . V.fromList . toList <$> distributeFor blobs go
  where
    go :: (Member (Error SomeException) sig, Member Task sig, Carrier sig m) => Blob -> m File
    go blob@Blob{..} = (doParse blob >>= withSomeTerm renderToSymbols) `catchError` (\(SomeException e) -> pure $ errorFile (show e))
      where
        blobLanguage' = blobLanguage blob
        blobPath' = pack $ blobPath blob
        errorFile e = File blobPath' (bridging # blobLanguage blob) mempty (V.fromList [ParseError (T.pack e)]) blobOid

        symbolsToSummarize :: [Text]
        symbolsToSummarize = ["Function", "Method", "Class", "Module", "Call", "Send"]

        renderToSymbols :: (IsTaggable f, Applicative m) => Term f Loc -> m File
        renderToSymbols term = pure $ tagsToFile (runTagging blob symbolsToSummarize term)

        tagsToFile :: [Tag] -> File
        tagsToFile tags = File blobPath' (bridging # blobLanguage') (V.fromList (fmap tagToSymbol tags)) mempty blobOid

        tagToSymbol :: Tag -> Symbol
        tagToSymbol Tag{..}
          = Symbol
          { symbol = name
          , kind = kind
          , line = fromMaybe mempty line
          , span = converting #? span
          , docs = fmap Docstring docs
          }
