{-# LANGUAGE CPP, ConstraintKinds, Rank2Types, ScopedTypeVariables, TypeFamilies, TypeOperators #-}
{-# OPTIONS_GHC -Wno-missing-signatures -Wno-missing-export-lists #-}

-- This module is *NOT* included in any build targets It is where we
-- store code that is useful for debugging in GHCi but that takes too
-- much time to build regularly. If you need one of these functions,
-- copy it temporarily to Util or some other appropriate place. Be aware
-- that these functions put tremendous strain on the typechecker.

module Semantic.UtilDisabled where

import Prelude hiding (readFile)

import           Analysis.Abstract.Caching.FlowSensitive
import           Analysis.Abstract.Collecting
import           Control.Abstract
import           Control.Abstract.Heap (runHeapError)
import           Control.Abstract.ScopeGraph (runScopeError)
import           Control.Effect.Trace (runTraceByPrinting)
import           Control.Exception (displayException)
import           Data.Abstract.Address.Hole as Hole
import           Data.Abstract.Address.Monovariant as Monovariant
import           Data.Abstract.Address.Precise as Precise
import           Data.Abstract.Evaluatable
import           Data.Abstract.Module
import qualified Data.Abstract.ModuleTable as ModuleTable
import           Data.Abstract.Package
import           Data.Abstract.Value.Concrete as Concrete
import           Data.Abstract.Value.Type as Type
import           Data.Blob
import           Data.Blob.IO
import           Data.Graph (topologicalSort)
import           Data.Graph.ControlFlowVertex
import qualified Data.Language as Language
import           Data.List (uncons)
import           Data.Project hiding (readFile)
import           Data.Quieterm (Quieterm, quieterm)
import           Data.Sum (weaken)
import           Data.Term
import qualified Language.Go.Assignment
import qualified Language.PHP.Assignment
import qualified Language.Python.Assignment
import qualified Language.Ruby.Assignment
import qualified Language.TypeScript.Assignment
import           Parsing.Parser
import           Prologue
import           Semantic.Analysis
import           Semantic.Config
import           Semantic.Graph
import           Semantic.Task
import           Source.Loc
import           System.Exit (die)
import           System.FilePath.Posix (takeDirectory)

type ProjectEvaluator syntax =
  Project
  -> IO
      (Heap
      (Hole (Maybe Name) Precise)
      (Hole (Maybe Name) Precise)
      (Value
      (Quieterm (Sum syntax) Loc)
      (Hole (Maybe Name) Precise)),
      (ScopeGraph (Hole (Maybe Name) Precise),
      ModuleTable
      (Module
              (ModuleResult
              (Hole (Maybe Name) Precise)
              (Value
              (Quieterm (Sum syntax) Loc)
              (Hole (Maybe Name) Precise))))))

type FileTypechecker (syntax :: [* -> *]) qterm value address result
  = FilePath
  -> IO
       (Heap
          address
          address
          value,
        (ScopeGraph
           address,
         (Cache
            qterm
            address
            value,
          [Either
             (SomeError
                (Sum
                   '[BaseError
                       Type.TypeError,
                     BaseError
                       (AddressError
                          address
                          value),
                     BaseError
                       (EvalError
                          qterm
                          address
                          value),
                     BaseError
                       ResolutionError,
                     BaseError
                       (HeapError                          address),
                     BaseError
                       (ScopeError
                          address),
                     BaseError
                       (UnspecializedError
                          address
                          value),
                     BaseError
                       (LoadError
                          address
                          value)]))
             result])))

type EvalEffects qterm err = ResumableC (BaseError err)
                         (ResumableC (BaseError (AddressError Precise (Value qterm Precise)))
                         (ResumableC (BaseError ResolutionError)
                         (ResumableC (BaseError (EvalError qterm Precise (Value qterm Precise)))
                         (ResumableC (BaseError (HeapError Precise))
                         (ResumableC (BaseError (ScopeError Precise))
                         (ResumableC (BaseError (UnspecializedError Precise (Value qterm Precise)))
                         (ResumableC (BaseError (LoadError Precise (Value qterm Precise)))
                         (FreshC
                         (StateC (ScopeGraph Precise)
                         (StateC (Heap Precise Precise (Value qterm Precise))
                         (TraceByPrintingC
                         (LiftC IO))))))))))))

-- We can't go with the inferred type because this needs to be
-- polymorphic in @lang@.
justEvaluatingCatchingErrors :: ( hole ~ Hole (Maybe Name) Precise
                                , term ~ Quieterm (Sum lang) Loc
                                , value ~ Concrete.Value term hole
                                , Apply Show1 lang
                                )
  => Evaluator term hole
       value
       (ResumableWithC
          (BaseError (ValueError term hole))
          (ResumableWithC (BaseError (AddressError hole value))
          (ResumableWithC (BaseError ResolutionError)
          (ResumableWithC (BaseError (EvalError term hole value))
          (ResumableWithC (BaseError (HeapError hole))
          (ResumableWithC (BaseError (ScopeError hole))
          (ResumableWithC (BaseError (UnspecializedError hole value))
          (ResumableWithC (BaseError (LoadError hole value))
          (FreshC
          (StateC (ScopeGraph hole)
          (StateC (Heap hole hole (Concrete.Value (Quieterm (Sum lang) Loc) (Hole (Maybe Name) Precise)))
          (TraceByPrintingC
          (LiftC IO))))))))))))) a
     -> IO (Heap hole hole value, (ScopeGraph hole, a))
justEvaluatingCatchingErrors
  = runM
  . runEvaluator @_ @_ @(Value _ (Hole.Hole (Maybe Name) Precise))
  . raiseHandler runTraceByPrinting
  . runHeap
  . runScopeGraph
  . raiseHandler runFresh
  . resumingLoadError
  . resumingUnspecialized
  . resumingScopeError
  . resumingHeapError
  . resumingEvalError
  . resumingResolutionError
  . resumingAddressError
  . resumingValueError

checking
  = runM
  . runEvaluator
  . raiseHandler runTraceByPrinting
  . runHeap
  . runScopeGraph
  . raiseHandler runFresh
  . caching
  . providingLiveSet
  . fmap reassociate
  . runLoadError
  . runUnspecialized
  . runScopeError
  . runHeapError
  . runResolutionError
  . runEvalError
  . runAddressError
  . runTypes

callGraphProject
  :: (Language.SLanguage lang, Ord1 syntax,
      Declarations1 syntax,
      Evaluatable syntax,
      FreeVariables1 syntax,
      AccessControls1 syntax,
      HasPrelude lang, Functor syntax,
      VertexDeclarationWithStrategy
        (VertexDeclarationStrategy syntax)
        syntax
        syntax) =>
     Parser
       (Term syntax Loc)
     -> Proxy lang
     -> [FilePath]
     -> IO
          (Graph ControlFlowVertex,
           [Module ()])
callGraphProject parser proxy paths = runTask' $ do
  blobs <- catMaybes <$> traverse readBlobFromFile (flip File (Language.reflect proxy) <$> paths)
  package <- fmap snd <$> parsePackage parser (Project (takeDirectory (maybe "/" fst (uncons paths))) blobs (Language.reflect proxy) [])
  modules <- topologicalSort <$> runImportGraphToModules proxy package
  x <- runCallGraph proxy False modules package
  pure (x, (() <$) <$> modules)

scopeGraphRubyProject :: ProjectEvaluator Language.Ruby.Assignment.Syntax
scopeGraphRubyProject = justEvaluatingCatchingErrors <=< evaluateProjectForScopeGraph (Proxy @'Language.Ruby) rubyParser

scopeGraphPHPProject :: ProjectEvaluator Language.PHP.Assignment.Syntax
scopeGraphPHPProject = justEvaluatingCatchingErrors <=< evaluateProjectForScopeGraph (Proxy @'Language.PHP) phpParser

scopeGraphPythonProject :: ProjectEvaluator Language.Python.Assignment.Syntax
scopeGraphPythonProject = justEvaluatingCatchingErrors <=< evaluateProjectForScopeGraph (Proxy @'Language.Python) pythonParser

scopeGraphGoProject :: ProjectEvaluator Language.Go.Assignment.Syntax
scopeGraphGoProject = justEvaluatingCatchingErrors <=< evaluateProjectForScopeGraph (Proxy @'Language.Go) goParser

scopeGraphTypeScriptProject :: ProjectEvaluator Language.TypeScript.Assignment.Syntax
scopeGraphTypeScriptProject = justEvaluatingCatchingErrors <=< evaluateProjectForScopeGraph (Proxy @'Language.TypeScript) typescriptParser

scopeGraphJavaScriptProject :: ProjectEvaluator Language.TypeScript.Assignment.Syntax
scopeGraphJavaScriptProject = justEvaluatingCatchingErrors <=< evaluateProjectForScopeGraph (Proxy @'Language.TypeScript) typescriptParser

callGraphRubyProject :: [FilePath] -> IO (Graph ControlFlowVertex, [Module ()])
callGraphRubyProject = callGraphProject rubyParser (Proxy @'Language.Ruby)

evalJavaScriptProject :: FileEvaluator Language.TypeScript.Assignment.Syntax
evalJavaScriptProject = justEvaluating <=< evaluateProject (Proxy :: Proxy 'Language.JavaScript) typescriptParser

typecheckGoFile :: ( syntax ~ Language.Go.Assignment.Syntax
                   , qterm ~ Quieterm (Sum syntax) Loc
                   , value ~ Type
                   , address ~ Monovariant
                   , result ~ (ModuleTable (Module (ModuleResult address value))))
                => FileTypechecker syntax qterm value address result
typecheckGoFile = checking <=< evaluateProjectWithCaching (Proxy :: Proxy 'Language.Go) goParser

typecheckRubyFile :: ( syntax ~ Language.Ruby.Assignment.Syntax
                   , qterm ~ Quieterm (Sum syntax) Loc
                   , value ~ Type
                   , address ~ Monovariant
                   , result ~ (ModuleTable (Module (ModuleResult address value))))
                  => FileTypechecker syntax qterm value address result
typecheckRubyFile = checking <=< evaluateProjectWithCaching (Proxy :: Proxy 'Language.Ruby) rubyParser

evaluateProjectForScopeGraph :: ( term ~ Term (Sum syntax) Loc
                              , qterm ~ Quieterm (Sum syntax) Loc
                              , address ~ Hole (Maybe Name) Precise
                              , LanguageSyntax lang syntax
                              )
                             => Proxy (lang :: Language.Language)
                             -> Parser term
                             -> Project
                             -> IO (Evaluator qterm address
                                    (Value qterm address)
                                    (ResumableWithC (BaseError (ValueError qterm address))
                               (ResumableWithC (BaseError (AddressError address (Value qterm address)))
                               (ResumableWithC (BaseError ResolutionError)
                               (ResumableWithC (BaseError (EvalError qterm address (Value qterm address)))
                               (ResumableWithC (BaseError (HeapError address))
                               (ResumableWithC (BaseError (ScopeError address))
                               (ResumableWithC (BaseError (UnspecializedError address (Value qterm address)))
                               (ResumableWithC (BaseError (LoadError address (Value qterm address)))
                               (FreshC
                               (StateC (ScopeGraph address)
                               (StateC (Heap address address (Value qterm address))
                               (TraceByPrintingC
                               (LiftC IO)))))))))))))
                             (ModuleTable (Module
                                (ModuleResult address (Value qterm address)))))
evaluateProjectForScopeGraph proxy parser project = runTask' $ do
  package <- fmap quieterm <$> parsePythonPackage parser project
  modules <- topologicalSort <$> runImportGraphToModules proxy package
  trace $ "evaluating with load order: " <> show (map (modulePath . moduleInfo) modules)
  pure (id @(Evaluator _ (Hole.Hole (Maybe Name) Precise) (Value _ (Hole.Hole (Maybe Name) Precise)) _ _)
       (runModuleTable
       (runModules (ModuleTable.modulePaths (packageModules package))
       (raiseHandler (runReader (packageInfo package))
       (raiseHandler (evalState (lowerBound @Span))
       (raiseHandler (runReader (lowerBound @Span))
       (evaluate proxy (runDomainEffects (evalTerm withTermSpans)) modules)))))))

evaluateProjectWithCaching :: ( term ~ Term (Sum syntax) Loc
                              , qterm ~ Quieterm (Sum syntax) Loc
                              , LanguageSyntax lang syntax
                              )
                           => Proxy (lang :: Language.Language)
                           -> Parser term
                          -> FilePath
                          -> IO (Evaluator qterm Monovariant Type
                                  (ResumableC (BaseError Type.TypeError)
                                  (StateC TypeMap
                                  (ResumableC (BaseError (AddressError Monovariant Type))
                                  (ResumableC (BaseError (EvalError qterm Monovariant Type))
                                  (ResumableC (BaseError ResolutionError)
                                  (ResumableC (BaseError (HeapError Monovariant))
                                  (ResumableC (BaseError (ScopeError Monovariant))
                                  (ResumableC (BaseError (UnspecializedError Monovariant Type))
                                  (ResumableC (BaseError (LoadError Monovariant Type))
                                  (ReaderC (Live Monovariant)
                                  (NonDetC
                                  (ReaderC (Analysis.Abstract.Caching.FlowSensitive.Cache (Data.Quieterm.Quieterm (Sum syntax) Loc) Monovariant Type)
                                  (StateC (Analysis.Abstract.Caching.FlowSensitive.Cache (Data.Quieterm.Quieterm (Sum syntax) Loc) Monovariant Type)
                                  (FreshC
                                  (StateC (ScopeGraph Monovariant)
                                  (StateC (Heap Monovariant Monovariant Type)
                                  (TraceByPrintingC
                                   (LiftC IO))))))))))))))))))
                                 (ModuleTable (Module (ModuleResult Monovariant Type))))
evaluateProjectWithCaching proxy parser path = runTask' $ do
  project <- readProject Nothing path (Language.reflect proxy) []
  package <- fmap (quieterm . snd) <$> parsePackage parser project
  modules <- topologicalSort <$> runImportGraphToModules proxy package
  pure (id @(Evaluator _ Monovariant _ _ _)
       (raiseHandler (runReader (packageInfo package))
       (raiseHandler (evalState (lowerBound @Span))
       (raiseHandler (runReader (lowerBound @Span))
       (runModuleTable
       (runModules (ModuleTable.modulePaths (packageModules package))
       (evaluate proxy (runDomainEffects (evalTerm withTermSpans)) modules)))))))

type LanguageSyntax lang syntax = ( Language.SLanguage lang
                                  , HasPrelude lang
                                  , Apply Eq1 syntax
                                  , Apply Ord1 syntax
                                  , Apply Show1 syntax
                                  , Apply Functor syntax
                                  , Apply Foldable syntax
                                  , Apply Evaluatable syntax
                                  , Apply Declarations1 syntax
                                  , Apply AccessControls1 syntax
                                  , Apply FreeVariables1 syntax)

evaluatePythonProjects :: ( term ~ Term (Sum Language.Python.Assignment.Syntax) Loc
                          , qterm ~ Quieterm (Sum Language.Python.Assignment.Syntax) Loc
                          )
                       => Proxy 'Language.Python
                       -> Parser term
                       -> Language.Language
                       -> FilePath
                       -> IO (Evaluator qterm Precise
                               (Value qterm Precise)
                               (EvalEffects qterm (ValueError qterm Precise))
                               (ModuleTable (Module (ModuleResult Precise (Value qterm Precise)))))
evaluatePythonProjects proxy parser lang path = runTask' $ do
  project <- readProject Nothing path lang []
  package <- fmap quieterm <$> parsePythonPackage parser project
  modules <- topologicalSort <$> runImportGraphToModules proxy package
  trace $ "evaluating with load order: " <> show (map (modulePath . moduleInfo) modules)
  pure (id @(Evaluator _ Precise (Value _ Precise) _ _)
       (runModuleTable
       (runModules (ModuleTable.modulePaths (packageModules package))
       (raiseHandler (runReader (packageInfo package))
       (raiseHandler (evalState (lowerBound @Span))
       (raiseHandler (runReader (lowerBound @Span))
       (evaluate proxy (runDomainEffects (evalTerm withTermSpans)) modules)))))))

evaluatePythonProject :: ( syntax ~ Language.Python.Assignment.Syntax
                   , qterm ~ Quieterm (Sum syntax) Loc
                   , value ~ (Concrete.Value qterm address)
                   , address ~ Precise
                   , result ~ (ModuleTable (Module (ModuleResult address value)))) => FilePath
     -> IO
          (Heap address address value,
           (ScopeGraph address,
             Either
                (SomeError
                   (Sum
                      '[BaseError
                          (ValueError qterm address),
                        BaseError
                          (AddressError
                             address
                             value),
                        BaseError
                          ResolutionError,
                        BaseError
                          (EvalError
                             qterm
                             address
                             value),
                        BaseError
                          (HeapError
                             address),
                        BaseError
                          (ScopeError
                             address),
                        BaseError
                          (UnspecializedError
                             address
                             value),
                        BaseError
                          (LoadError
                             address
                             value)]))
                result))
evaluatePythonProject = justEvaluating <=< evaluatePythonProjects (Proxy @'Language.Python) pythonParser Language.Python
