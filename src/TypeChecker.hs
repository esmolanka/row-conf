{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase          #-}

module TypeChecker where

import Control.Monad.Except
import Control.Monad.State
import Control.Monad.Reader

import Data.Functor.Foldable (cata, Fix (..))
import qualified Data.Set as S

import Types
import Context (Context)
import qualified Context as Ctx
import Pretty

data TCError
  = CannotUnify Type Type
  | CannotUnifyLabel Label Type Type
  | InfiniteType Type
  | RecursiveRowType Type
  | KindMismatch Kind Kind
  | VariableNotFound Expr
  deriving (Show)

newtype FreshSupply = FreshSupply { getFreshName :: Int }

newTyVar :: (MonadState FreshSupply m) => Kind -> m Type
newTyVar kind = do
  name <- gets getFreshName
  modify (\s -> s { getFreshName = getFreshName s + 1 })
  return $ Fix $ TVar $ TyVar name kind

instantiate :: forall m. (MonadState FreshSupply m) => TyScheme -> m Type
instantiate TyScheme{..} = do
  subst <- foldSubsts <$> mapM mkFreshVar tsForall
  return $ applySubst subst tsBody
  where
    mkFreshVar :: TyVar -> m TySubst
    mkFreshVar tv = singletonSubst <$> pure tv <*> newTyVar (tvKind tv)

generalize :: (MonadReader Context m) => Type -> m TyScheme
generalize ty = do
  freeInCtx <- asks freeTyVars
  return (TyScheme (S.toList (freeTyVars ty `S.difference` freeInCtx)) ty)

----------------------------------------------------------------------
-- Unification

unifyBaseTypes :: (MonadState FreshSupply m, MonadError TCError m) => BaseType -> BaseType -> m ()
unifyBaseTypes a b =
  unless (a == b) $
    throwError (CannotUnify (Fix (T a)) (Fix (T b)))

unifyVars :: (MonadState FreshSupply m, MonadError TCError m) => TyVar -> TyVar -> m TySubst
unifyVars a b = do
  unless (tvKind a == tvKind b) $
    throwError (KindMismatch (tvKind a) (tvKind b))
  return (singletonSubst a (Fix (TVar b)))

unifyIs :: (MonadState FreshSupply m, MonadError TCError m) => TyVar -> Type -> m TySubst
unifyIs tv typ
  | tv `S.member` freeTyVars typ = throwError (InfiniteType typ)
  | otherwise = return (singletonSubst tv typ)

unify :: (MonadState FreshSupply m, MonadError TCError m) => Type -> Type -> m TySubst
unify (Fix l) (Fix r) =
  case (l, r) of
    (TVar x, TVar y) -> unifyVars x y
    (TVar x, typ)    -> x `unifyIs` Fix typ
    (typ,    TVar y) -> y `unifyIs` Fix typ
    (T x,    T y)    -> emptySubst <$ unifyBaseTypes x y

    (TList x,    TList y)    -> unify x y
    (TRecord x,  TRecord y)  -> unify x y
    (TVariant x, TVariant y) -> unify x y
    (TPresent,   TPresent)   -> pure emptySubst
    (TAbsent,    TAbsent)    -> pure emptySubst
    (TArrow a f x, TArrow b g y) -> do
      s1 <- unify a b
      s2 <- unify (applySubst s1 f) (applySubst s1 g)
      let s3 = s2 `composeSubst` s1
      s4 <- unify (applySubst s3 x) (applySubst s3 y)
      pure $ s4 `composeSubst` s3

    (TRowEmpty,  TRowEmpty) -> pure emptySubst

    (TRowExtend lbl pty fty tail, TRowExtend lbl' pty' fty' tail') -> do
      (pty'', fty'', tail'', s1) <- rewriteRow lbl lbl' pty' fty' tail'
      case getRowTail tail of
        Just r | domSubst r s1 ->
                   throwError (RecursiveRowType (Fix (TRowExtend lbl' pty'' fty'' tail'')))
        _ -> do
          s2 <- unify (applySubst s1 pty) (applySubst s1 pty'')
          let s3 = composeSubst s2 s1
          s4 <- unify (applySubst s3 fty) (applySubst s3 fty'')
          let s5 = composeSubst s4 s3
          s6 <- unify (applySubst s5 tail) (applySubst s5 tail'')
          return (composeSubst s6 s5)

    (TRowEmpty, TRowExtend lbl p f r) ->
      unify
        (Fix (TRowExtend lbl (Fix TAbsent) f (Fix TRowEmpty)))
        (Fix (TRowExtend lbl p f r))

    (TRowExtend lbl p f r, TRowEmpty) ->
      unify
        (Fix (TRowExtend lbl p f r))
        (Fix (TRowExtend lbl (Fix TAbsent) f (Fix TRowEmpty)))

    _ -> throwError $ CannotUnify (Fix l) (Fix r)

rewriteRow
  :: (MonadState FreshSupply m, MonadError TCError m) =>
     Label -> Label -> Type -> Type -> Type -> m (Type, Type, Type, TySubst)
rewriteRow newLbl lbl pty fty tail =
  if newLbl == lbl
  then return (pty, fty, tail, emptySubst)
  else
    case tail of
      Fix (TVar alpha) -> do
        beta  <- newTyVar Row
        gamma <- newTyVar Star
        theta <- newTyVar Presence
        s     <- alpha `unifyIs` Fix (TRowExtend newLbl theta gamma beta)
        return (theta, gamma, applySubst s (Fix (TRowExtend lbl pty fty beta)), s)
      Fix (TRowExtend lbl' pty' fty' tail') -> do
        (pty'', fty'', tail'', s) <- rewriteRow newLbl lbl' pty' fty' tail'
        return (pty'', fty'', Fix (TRowExtend lbl pty fty tail''), s)
      Fix TRowEmpty -> do
        gamma <- newTyVar Star
        return (Fix TAbsent, gamma, Fix (TRowExtend lbl pty fty (Fix TRowEmpty)), emptySubst)
      _other ->
        error $ "Unexpected type: " ++ show tail

----------------------------------------------------------------------
-- Type inference

inferType
  :: forall m. (MonadState FreshSupply m, MonadReader Context m, MonadError TCError m) =>
     Expr
  -> m (TySubst, Type, Type)
inferType = cata alg
  where
    alg :: ExprF (m (TySubst, Type, Type)) -> m (TySubst, Type, Type)
    alg = \case
      Var pos x n -> do
        mts <- asks (Ctx.lookup x n)
        case mts of
          Nothing -> throwError (VariableNotFound (Fix (Var pos x n)))
          Just sigma -> do
            typ <- instantiate sigma
            eff <- newTyVar Row
            return
              ( emptySubst
              , typ
              , eff
              )

      Lambda _pos x b -> do
        tv <- newTyVar Star
        (s1, t1, eff1) <- Ctx.with x (TyScheme [] tv) b
        eff <- newTyVar Row
        return
          ( s1
          , Fix (TArrow (applySubst s1 tv) eff1 t1)
          , eff
          )

      App _pos f a -> do
        (sf, tf, eff1) <- f
        (sa, ta, eff2) <- Ctx.withSubst sf a
        tr <- newTyVar Star
        sr <- unify (applySubst sa tf) (Fix (TArrow ta eff2 tr))
        se <- unify (applySubst (sr `composeSubst` sa) eff1) (applySubst sr eff2)
        return
          ( se `composeSubst` sr `composeSubst` sa `composeSubst` sf
          , applySubst (se `composeSubst` sr) tr
          , applySubst (se `composeSubst` sr) eff2
          )

      Let _pos x e b -> do
        (se, te, eff1) <- e
        sf <- unify eff1 (Fix TRowEmpty)
        (sb, tb, eff2) <- Ctx.withSubst (sf `composeSubst` se) $ do
          scheme <- generalize te
          Ctx.with x scheme $ b
        return
          ( sb `composeSubst` sf `composeSubst` se
          , tb
          , eff2
          )

      Const _pos c -> do
        typ <- instantiate $ typeSchemeOfConst c
        eff <- newTyVar Row
        return (emptySubst, typ, eff)


inferExprType
  :: forall m. (MonadState FreshSupply m, MonadReader Context m, MonadError TCError m) =>
     Expr
  -> m (Type, Type)
inferExprType expr = do
  (se, te, fe) <- inferType expr
  return (applySubst se te, applySubst se fe)

type InferM = ExceptT TCError (StateT FreshSupply (Reader Context))

primitives :: Context
primitives =
  Ctx.extend (Variable "cons")  (typeSchemeOfConst ListCons) $
  Ctx.extend (Variable "nil")   (typeSchemeOfConst ListEmpty) $

  Ctx.extend (Variable "read")  (typeSchemeOfConst Read) $
  Ctx.extend (Variable "print") (typeSchemeOfConst Print) $
  Ctx.extend (Variable "pure")  (typeSchemeOfConst Pure) $

  Ctx.extend (Variable "*")     (typeSchemeOfConst Multiply) $
  Ctx.extend (Variable "/")     (typeSchemeOfConst Divide) $

  Ctx.extend (Variable "raise") (typeSchemeOfConst Raise) $
  Ctx.extend (Variable "total") (typeSchemeOfConst Total) $
  Ctx.extend (Variable "catch") (typeSchemeOfConst Catch) $
  Ctx.empty

runInfer :: InferM a -> Either TCError a
runInfer =
  flip runReader primitives .
  flip evalStateT (FreshSupply 0) .
  runExceptT

showType :: Expr -> IO ()
showType e =
  case runInfer (inferExprType e) of
    Left e   -> putStrLn ("typecheck error:\n" ++ show e)
    Right (ty,eff) -> putStrLn $ pp (ppType ty) ++ "\n" ++ pp (ppType eff)
