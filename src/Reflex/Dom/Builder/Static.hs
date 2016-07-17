{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
module Reflex.Dom.Builder.Static where

import Control.Monad.Identity
import Control.Monad.Ref
import Data.Dependent.Sum (DSum (..))
import Reflex
import Reflex.Dom.Builder.Class
import Reflex.Dom.PerformEvent.Base
import Reflex.Dom.PerformEvent.Class
import Reflex.Dom.PostBuild.Class
import Reflex.Dom.Widget.Basic (applyMap)
import Reflex.Host.Class

import Blaze.ByteString.Builder.Html.Utf8
import Control.Lens hiding (element)
import Control.Monad.Exception
import Control.Monad.State.Strict
import Control.Monad.Trans.Control
import Data.ByteString (ByteString)
import Data.ByteString.Builder (toLazyByteString)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map as Map
import Data.Monoid
import Data.Text.Encoding


newtype StaticDomBuilderT t m a = StaticDomBuilderT
    { unStaticDomBuilderT :: StateT [Behavior t ByteString] m a -- Accumulated Html will be in revesed order
    }
  deriving (Functor, Applicative, Monad, MonadFix, MonadIO, MonadException, MonadAsyncException)

instance MonadTransControl (StaticDomBuilderT t) where
  type StT (StaticDomBuilderT t) a = StT (StateT [Behavior t ByteString]) a
  liftWith = defaultLiftWith StaticDomBuilderT unStaticDomBuilderT
  restoreT = defaultRestoreT StaticDomBuilderT

instance MonadTrans (StaticDomBuilderT t) where
  lift = StaticDomBuilderT . lift

runStaticDomBuilderT :: (Monad m, Reflex t) => StaticDomBuilderT t m a -> m (a, Behavior t ByteString)
runStaticDomBuilderT (StaticDomBuilderT a) = do
  (result, a') <- runStateT a []
  return (result, mconcat $ reverse a')

instance MonadReflexCreateTrigger t m => MonadReflexCreateTrigger t (StaticDomBuilderT t m) where
  {-# INLINABLE newEventWithTrigger #-}
  newEventWithTrigger = lift . newEventWithTrigger
  {-# INLINABLE newFanEventWithTrigger #-}
  newFanEventWithTrigger f = lift $ newFanEventWithTrigger f

instance PerformEvent t m => PerformEvent t (StaticDomBuilderT t m) where
  type Performable (StaticDomBuilderT t m) = Performable m
  {-# INLINABLE performEvent_ #-}
  performEvent_ e = lift $ performEvent_ e
  {-# INLINABLE performEvent #-}
  performEvent e = lift $ performEvent e

instance MonadSample t m => MonadSample t (StaticDomBuilderT t m) where
  {-# INLINABLE sample #-}
  sample = lift . sample

instance MonadHold t m => MonadHold t (StaticDomBuilderT t m) where
  {-# INLINABLE hold #-}
  hold v0 v' = lift $ hold v0 v'
  {-# INLINABLE holdDyn #-}
  holdDyn v0 v' = lift $ holdDyn v0 v'
  {-# INLINABLE holdIncremental #-}
  holdIncremental v0 v' = lift $ holdIncremental v0 v'

instance (Reflex t, Monad m, MonadHold t (StateT [Behavior t ByteString] m)) => Deletable t (StaticDomBuilderT t m) where
  {-# INLINABLE deletable #-}
  deletable delete (StaticDomBuilderT a) = StaticDomBuilderT $ do
    (result, a') <- lift $ runStateT a []
    let html = mconcat $ reverse a'
    b <- hold html (mempty <$ delete)
    modify (join b:)
    return result

instance (Monad m, Ref m ~ Ref IO, Reflex t) => TriggerEvent t (StaticDomBuilderT t m) where
  {-# INLINABLE newTriggerEvent #-}
  newTriggerEvent = return (never, const $ return ())
  {-# INLINABLE newTriggerEventWithOnComplete #-}
  newTriggerEventWithOnComplete = return (never, \_ _ -> return ())
  {-# INLINABLE newEventWithLazyTriggerWithOnComplete #-}
  newEventWithLazyTriggerWithOnComplete _ = return never

type SupportsStaticDomBuilder t m = (Reflex t, MonadIO m, MonadHold t m, MonadFix m, PerformEvent t m, Performable m ~ m, MonadReflexCreateTrigger t m, Deletable t m, MonadRef m, Ref m ~ Ref IO)

data StaticDomSpace

instance DomSpace StaticDomSpace where
  type RawElement StaticDomSpace = ByteString

instance SupportsStaticDomBuilder t m => DomBuilder t (StaticDomBuilderT t m) where
  type DomBuilderSpace (StaticDomBuilderT t m) = StaticDomSpace
  {-# INLINABLE textNode #-}
  textNode (TextNodeConfig contents) = StaticDomBuilderT $ do
    modify $ (:) $ constant $ BL.toStrict $ toLazyByteString $ fromHtmlEscapedText contents
    return TextNode

  {-# INLINABLE element #-}
  element elementTag cfg child = do
    let toAttr (_mns, k) v = encodeUtf8 k <> "=\"" <> BL.toStrict (toLazyByteString $ fromHtmlEscapedText v) <> "\""
    es <- newFanEventWithTrigger $ \_ _ -> return (return ())
    StaticDomBuilderT $ do
      (result, innerHtml) <- lift $ runStaticDomBuilderT child
      attrs0 <- foldDyn applyMap (cfg ^. initialAttributes) (cfg ^. modifyAttributes)
      let attrs1 = ffor (current attrs0) $ mconcat . fmap (\(k, v) -> " " <> toAttr k v) . Map.toList
      let tagBS = encodeUtf8 elementTag
      let open = mconcat [constant ("<" <> tagBS <> " "), attrs1, constant ">"]
      let close = constant $ "</" <> tagBS <> ">" -- TODO handle elements without closing tags
      modify $ (:) $ mconcat $ [open, innerHtml, close]
      return (Element es (error "Static.element RawElement was used"), result)

  {-# INLINABLE placeholder #-}
  placeholder (PlaceholderConfig toInsertAbove _delete) = StaticDomBuilderT $ do
    result <- lift $ performEvent (fmap runStaticDomBuilderT toInsertAbove)
    acc <- foldDyn (:) [] (fmap snd result)
    modify $ (:) $ join $ mconcat . reverse <$> current acc
    return $ Placeholder (fmap fst result) never

  {-# INLINABLE inputElement #-}
  inputElement cfg = do
    (e, _result) <- element "input" (cfg ^. inputElementConfig_elementConfig) $ return ()
    let v0 = constDyn $ cfg ^. inputElementConfig_initialValue
    let c0 = constDyn $ cfg ^. inputElementConfig_initialChecked
    let hasFocus = constDyn False -- TODO should this be coming from initialAtttributes
    return $ InputElement v0 c0 never hasFocus e

  {-# INLINABLE textAreaElement #-}
  textAreaElement cfg = do
    (e, _domElement) <- element "textarea" (cfg ^. textAreaElementConfig_elementConfig) $ return ()
    let v0 = constDyn $ cfg ^. textAreaElementConfig_initialValue
    let hasFocus = constDyn False -- TODO should this be coming from initialAtttributes
    return $ TextAreaElement v0 never hasFocus e

--TODO: Make this more abstract --TODO: Put the WithWebView underneath PerformEventT - I think this would perform better
type StaticWidget x = PostBuildT Spider (StaticDomBuilderT Spider (PerformEventT Spider (SpiderHost Global)))

renderStatic :: StaticWidget x a -> IO (a, ByteString)
renderStatic w = do
  runSpiderHost $ do
    (postBuild, postBuildTriggerRef) <- newEventWithTriggerRef
    ((res, bs), FireCommand fire) <- hostPerformEventT $ runStaticDomBuilderT (runPostBuildT w postBuild)
    mPostBuildTrigger <- readRef postBuildTriggerRef
    forM_ mPostBuildTrigger $ \postBuildTrigger -> fire [postBuildTrigger :=> Identity ()] $ return ()
    bs' <- sample bs
    return (res, bs')
