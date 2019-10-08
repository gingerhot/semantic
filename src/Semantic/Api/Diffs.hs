{-# LANGUAGE AllowAmbiguousTypes, ConstraintKinds, LambdaCase, MonoLocalBinds, QuantifiedConstraints, RankNTypes #-}
module Semantic.Api.Diffs
  ( parseDiffBuilder
  , DiffOutputFormat(..)
  , diffGraph

  , decoratingDiffWith
  , DiffEffects

  , legacySummarizeDiffParsers
  , LegacySummarizeDiff(..)
  , summarizeDiffParsers
  , SummarizeDiff(..)
  ) where

import           Analysis.ConstructorName (ConstructorName)
import           Analysis.Decorator (decoratorWithAlgebra)
import           Analysis.TOCSummary (Declaration, HasDeclaration, declarationAlgebra)
import           Control.Effect.Error
import           Control.Effect.Parse
import           Control.Effect.Reader
import           Control.Exception
import           Control.Lens
import           Control.Monad.IO.Class
import           Data.Blob
import           Data.ByteString.Builder
import           Data.Graph
import           Data.JSON.Fields
import           Data.Language
import           Data.ProtoLens (defMessage)
import           Data.Term
import qualified Data.Text as T
import           Diffing.Algorithm (Diffable)
import           Diffing.Interpreter (DiffTerms(..))
import           Parsing.Parser
import           Prologue
import           Proto.Semantic as P hiding (Blob, BlobPair)
import           Proto.Semantic_Fields as P
import           Proto.Semantic_JSON()
import           Rendering.Graph
import           Rendering.JSON hiding (JSON)
import qualified Rendering.JSON
import           Rendering.TOC
import           Semantic.Api.Bridge
import           Semantic.Config
import           Semantic.Task as Task
import           Semantic.Telemetry as Stat
import           Serializing.Format hiding (JSON)
import qualified Serializing.Format as Format
import           Source.Loc

data DiffOutputFormat
  = DiffJSONTree
  | DiffJSONGraph
  | DiffSExpression
  | DiffShow
  | DiffDotGraph
  deriving (Eq, Show)

parseDiffBuilder :: (Traversable t, DiffEffects sig m) => DiffOutputFormat -> t BlobPair -> m Builder
parseDiffBuilder DiffJSONTree    = distributeFoldMap jsonDiff >=> serialize Format.JSON -- NB: Serialize happens at the top level for these two JSON formats to collect results of multiple blob pairs.
parseDiffBuilder DiffJSONGraph   = diffGraph >=> serialize Format.JSON
parseDiffBuilder DiffSExpression = distributeFoldMap (diffWith sexprDiffParsers sexprDiff)
parseDiffBuilder DiffShow        = distributeFoldMap (diffWith showDiffParsers showDiff)
parseDiffBuilder DiffDotGraph    = distributeFoldMap (diffWith dotGraphDiffParsers dotGraphDiff)

jsonDiff :: DiffEffects sig m => BlobPair -> m (Rendering.JSON.JSON "diffs" SomeJSON)
jsonDiff blobPair = diffWith jsonTreeDiffParsers (pure . jsonTreeDiff blobPair) blobPair `catchError` jsonError blobPair

jsonError :: Applicative m => BlobPair -> SomeException -> m (Rendering.JSON.JSON "diffs" SomeJSON)
jsonError blobPair (SomeException e) = pure $ renderJSONDiffError blobPair (show e)

diffGraph :: (Traversable t, DiffEffects sig m) => t BlobPair -> m DiffTreeGraphResponse
diffGraph blobs = do
  graph <- distributeFor blobs go
  pure $ defMessage & P.files .~ toList graph
  where
    go :: DiffEffects sig m => BlobPair -> m DiffTreeFileGraph
    go blobPair = diffWith jsonGraphDiffParsers (pure . jsonGraphDiff blobPair) blobPair
      `catchError` \(SomeException e) ->
        pure $ defMessage
          & P.path .~ path
          & P.language .~ lang
          & P.vertices .~ mempty
          & P.edges .~ mempty
          & P.errors .~ [defMessage & P.error .~ T.pack (show e)]
      where
        path = T.pack $ pathForBlobPair blobPair
        lang = bridging # languageForBlobPair blobPair

type DiffEffects sig m = (Member (Error SomeException) sig, Member (Reader Config) sig, Member Telemetry sig, Member Distribute sig, Member Parse sig, Carrier sig m, MonadIO m)


dotGraphDiffParsers :: Map Language (SomeParser DOTGraphDiff Loc)
dotGraphDiffParsers = aLaCarteParsers

class DiffTerms term => DOTGraphDiff term where
  dotGraphDiff :: (Carrier sig m, Member (Reader Config) sig) => DiffFor term Loc Loc -> m Builder

instance (ConstructorName syntax, Diffable syntax, Eq1 syntax, Hashable1 syntax, Traversable syntax) => DOTGraphDiff (Term syntax) where
  dotGraphDiff = serialize (DOT (diffStyle "diffs")) . renderTreeGraph


jsonGraphDiffParsers :: Map Language (SomeParser JSONGraphDiff Loc)
jsonGraphDiffParsers = aLaCarteParsers

class DiffTerms term => JSONGraphDiff term where
  jsonGraphDiff :: BlobPair -> DiffFor term Loc Loc -> DiffTreeFileGraph

instance (ConstructorName syntax, Diffable syntax, Eq1 syntax, Hashable1 syntax, Traversable syntax) => JSONGraphDiff (Term syntax) where
  jsonGraphDiff blobPair diff
    = let graph = renderTreeGraph diff
          toEdge (Edge (a, b)) = defMessage & P.source .~ a^.diffVertexId & P.target .~ b^.diffVertexId
          path = T.pack $ pathForBlobPair blobPair
          lang = bridging # languageForBlobPair blobPair
      in defMessage
           & P.path .~ path
           & P.language .~ lang
           & P.vertices .~ vertexList graph
           & P.edges .~ fmap toEdge (edgeList graph)
           & P.errors .~ mempty


jsonTreeDiffParsers :: Map Language (SomeParser JSONTreeDiff Loc)
jsonTreeDiffParsers = aLaCarteParsers

class DiffTerms term => JSONTreeDiff term where
  jsonTreeDiff :: BlobPair -> DiffFor term Loc Loc -> Rendering.JSON.JSON "diffs" SomeJSON

instance (Diffable syntax, Eq1 syntax, Hashable1 syntax, ToJSONFields1 syntax, Traversable syntax) => JSONTreeDiff (Term syntax) where
  jsonTreeDiff = renderJSONDiff


sexprDiffParsers :: Map Language (SomeParser SExprDiff Loc)
sexprDiffParsers = aLaCarteParsers

class DiffTerms term => SExprDiff term where
  sexprDiff :: (Carrier sig m, Member (Reader Config) sig) => DiffFor term Loc Loc -> m Builder

instance (ConstructorName syntax, Diffable syntax, Eq1 syntax, Hashable1 syntax, Traversable syntax) => SExprDiff (Term syntax) where
  sexprDiff = serialize (SExpression ByConstructorName)


showDiffParsers :: Map Language (SomeParser ShowDiff Loc)
showDiffParsers = aLaCarteParsers

class DiffTerms term => ShowDiff term where
  showDiff :: (Carrier sig m, Member (Reader Config) sig) => DiffFor term Loc Loc -> m Builder

instance (Diffable syntax, Eq1 syntax, Hashable1 syntax, Show1 syntax, Traversable syntax) => ShowDiff (Term syntax) where
  showDiff = serialize Show


legacySummarizeDiffParsers :: Map Language (SomeParser LegacySummarizeDiff Loc)
legacySummarizeDiffParsers = aLaCarteParsers

class DiffTerms term => LegacySummarizeDiff term where
  legacyDecorateTerm :: Blob -> term Loc -> term (Maybe Declaration)
  legacySummarizeDiff :: BlobPair -> DiffFor term (Maybe Declaration) (Maybe Declaration) -> Summaries

instance (Diffable syntax, Eq1 syntax, HasDeclaration syntax, Hashable1 syntax, Traversable syntax) => LegacySummarizeDiff (Term syntax) where
  legacyDecorateTerm = decoratorWithAlgebra . declarationAlgebra
  legacySummarizeDiff = renderToCDiff


summarizeDiffParsers :: Map Language (SomeParser SummarizeDiff Loc)
summarizeDiffParsers = aLaCarteParsers

class DiffTerms term => SummarizeDiff term where
  decorateTerm :: Blob -> term Loc -> term (Maybe Declaration)
  summarizeDiff :: BlobPair -> DiffFor term (Maybe Declaration) (Maybe Declaration) -> TOCSummaryFile

instance (Diffable syntax, Eq1 syntax, HasDeclaration syntax, Hashable1 syntax, Traversable syntax) => SummarizeDiff (Term syntax) where
  decorateTerm = decoratorWithAlgebra . declarationAlgebra
  summarizeDiff blobPair diff = foldr go (defMessage & P.path .~ path & P.language .~ lang) (diffTOC diff)
    where
      path = T.pack $ pathKeyForBlobPair blobPair
      lang = bridging # languageForBlobPair blobPair

      toChangeType = \case
        "added" -> ADDED
        "modified" -> MODIFIED
        "removed" -> REMOVED
        _ -> NONE

      go :: TOCSummary -> TOCSummaryFile -> TOCSummaryFile
      go TOCSummary{..} file = defMessage
        & P.path .~ file^.P.path
        & P.language .~ file^.P.language
        & P.changes .~ (defMessage & P.category .~ summaryCategoryName & P.term .~ summaryTermName & P.maybe'span .~ (converting #? summarySpan) & P.changeType .~ toChangeType summaryChangeType) : file^.P.changes
        & P.errors .~ file^.P.errors

      go ErrorSummary{..} file = defMessage
        & P.path .~ file^.P.path
        & P.language .~ file^.P.language
        & P.changes .~ file^.P.changes
        & P.errors .~ (defMessage & P.error .~ errorText & P.maybe'span .~ converting #? errorSpan) : file^.P.errors


-- | Parse a 'BlobPair' using one of the provided parsers, diff the resulting terms, and run an action on the abstracted diff.
--
-- This allows us to define features using an abstract interface, and use them with diffs for any parser whose terms support that interface.
diffWith
  :: (forall term . c term => DiffTerms term, DiffEffects sig m)
  => Map Language (SomeParser c Loc)                            -- ^ The set of parsers to select from.
  -> (forall term . c term => DiffFor term Loc Loc -> m output) -- ^ A function to run on the computed diff. Note that the diff is abstract (it’s the diff type corresponding to an abstract term type), but the term type is constrained by @c@, allowing you to do anything @c@ allows, and requiring that all the input parsers produce terms supporting @c@.
  -> BlobPair                                                   -- ^ The blob pair to parse.
  -> m output
diffWith parsers render blobPair = parsePairWith parsers (render <=< diffTerms blobPair) blobPair

-- | Parse a 'BlobPair' using one of the provided parsers, decorate the resulting terms, diff them, and run an action on the abstracted diff.
--
-- This allows us to define features using an abstract interface, and use them with diffs for any parser whose terms support that interface.
decoratingDiffWith
  :: forall ann c output m sig
  .  (forall term . c term => DiffTerms term, DiffEffects sig m)
  => Map Language (SomeParser c Loc)                            -- ^ The set of parsers to select from.
  -> (forall term . c term => Blob -> term Loc -> term ann)     -- ^ A function to decorate the terms, replacing their annotations and thus the annotations in the resulting diff.
  -> (forall term . c term => DiffFor term ann ann -> m output) -- ^ A function to run on the computed diff. Note that the diff is abstract (it’s the diff type corresponding to an abstract term type), but the term type is constrained by @c@, allowing you to do anything @c@ allows, and requiring that all the input parsers produce terms supporting @c@.
  -> BlobPair                                                   -- ^ The blob pair to parse.
  -> m output
decoratingDiffWith parsers decorate render blobPair = parsePairWith parsers (render <=< diffTerms blobPair . bimap (decorate blobL) (decorate blobR)) blobPair where
  (blobL, blobR) = fromThese errorBlob errorBlob (runJoin blobPair)
  errorBlob = Prelude.error "evaluating blob on absent side"

diffTerms :: (DiffTerms term, Member Telemetry sig, Carrier sig m, MonadIO m)
  => BlobPair -> These (term ann) (term ann) -> m (DiffFor term ann ann)
diffTerms blobs terms = time "diff" languageTag $ do
  let diff = diffTermPair terms
  diff <$ writeStat (Stat.count "diff.nodes" (bilength diff) languageTag)
  where languageTag = languageTagForBlobPair blobs
