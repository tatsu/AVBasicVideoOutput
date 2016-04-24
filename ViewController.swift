//
//  ViewController.swift
//  AVBasicVideoOutput
//
//  Created by Tatsuhiko Arai on 4/22/16.
//  Copyright © 2016 Apple. All rights reserved.
//

import UIKit
import AVFoundation
import MobileCoreServices

private let ONE_FRAME_DURATION = 0.03
private let LUMA_SLIDER_TAG = 0
private let CHROMA_SLIDER_TAG = 1

private let AVPlayerItemStatusContext = UnsafeMutablePointer<Void>(nil)

class ImagePickerController: UIImagePickerController {

    override func supportedInterfaceOrientations() -> UIInterfaceOrientationMask {
        return .Landscape
    }
}

class ViewController: UIViewController, AVPlayerItemOutputPullDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIPopoverControllerDelegate, UIGestureRecognizerDelegate {

    @IBOutlet weak var playerView: APLEAGLView!
    @IBOutlet weak var chromaLevelSlider: UISlider!
    @IBOutlet weak var lumaLevelSlider: UISlider!
    @IBOutlet weak var currentTime: UILabel!
    @IBOutlet weak var timeView: UIView!
    @IBOutlet weak var toolbar: UIToolbar!
    var popover: UIPopoverController?

    var videoOutput: AVPlayerItemVideoOutput!
    var displayLink: CADisplayLink!

    var _player: AVPlayer!
    var _myVideoOutputQueue: dispatch_queue_t!
    var _notificationToken: AnyObject!
    var _timeObserver: AnyObject!

    override func viewDidLoad() {
        super.viewDidLoad()

        // Do any additional setup after loading the view.
        self.playerView.lumaThreshold = self.lumaLevelSlider.value
        self.playerView.chromaThreshold = self.chromaLevelSlider.value

        _player = AVPlayer()
        self.addTimeObserverToPlayer()

        // Setup CADisplayLink which will callback displayPixelBuffer: at every vsync.
        self.displayLink = CADisplayLink(target: self, selector: #selector(displayLinkCallback(_:)))
        self.displayLink.addToRunLoop(NSRunLoop.currentRunLoop(), forMode: NSDefaultRunLoopMode)
        self.displayLink.paused = true

        // Setup AVPlayerItemVideoOutput with the required pixelbuffer attributes.
        let pixBuffAttributes: [String: AnyObject] = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)]
        self.videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: pixBuffAttributes)
        _myVideoOutputQueue = dispatch_queue_create("myVideoOutputQueue", DISPATCH_QUEUE_SERIAL)
        self.videoOutput.setDelegate(self, queue: _myVideoOutputQueue)
    }

    override func viewWillAppear(animated: Bool) {
        self.addObserver(self, forKeyPath: "player.currentItem.status", options: .New, context: AVPlayerItemStatusContext)
        self.addTimeObserverToPlayer()

        super.viewWillAppear(animated)
    }

    override func viewWillDisappear(animated: Bool) {
        self.removeObserver(self, forKeyPath: "player.currentItem.status", context: AVPlayerItemStatusContext)
        self.removeTimeObserverFromPlayer()

        if _notificationToken != nil {
            NSNotificationCenter.defaultCenter().removeObserver(_notificationToken, name: AVPlayerItemDidPlayToEndTimeNotification, object: _player.currentItem)
            _notificationToken = nil
        }
        
        super.viewWillDisappear(animated)
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    

    /*
    // MARK: - Navigation

    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepareForSegue(segue: UIStoryboardSegue, sender: AnyObject?) {
        // Get the new view controller using segue.destinationViewController.
        // Pass the selected object to the new view controller.
    }
    */

    // MARK: - Utilities

    @IBAction func updateLevels(sender: AnyObject) {
        switch sender.tag {
        case LUMA_SLIDER_TAG:
            self.playerView.lumaThreshold = self.lumaLevelSlider.value
        case CHROMA_SLIDER_TAG:
            self.playerView.chromaThreshold = self.chromaLevelSlider.value
        default:
            break
        }
    }

    @IBAction func loadMovieFromCameraRoll(sender: UIBarButtonItem) {
        _player.pause()
        self.displayLink.paused = true

        if let popover = self.popover where popover.popoverVisible {
            popover.dismissPopoverAnimated(true)
        }
        // Initialize UIImagePickerController to select a movie from the camera roll
        let videoPicker = ImagePickerController()
        videoPicker.delegate = self
        videoPicker.modalPresentationStyle = .CurrentContext
        videoPicker.sourceType = .SavedPhotosAlbum;
        videoPicker.mediaTypes = [kUTTypeMovie as String]

        if UIDevice.currentDevice().userInterfaceIdiom == .Pad {
            let popover = UIPopoverController(contentViewController: videoPicker)
            popover.delegate = self;
            popover.presentPopoverFromBarButtonItem(sender, permittedArrowDirections: .Down, animated: true)
            self.popover = popover
        } else {
            self.presentViewController(videoPicker, animated: true, completion: nil)
        }
    }

    @IBAction func handleTapGesture(tapGestureRecognizer: UITapGestureRecognizer) {
        self.toolbar.hidden = !self.toolbar.hidden;
    }

    override func supportedInterfaceOrientations() -> UIInterfaceOrientationMask {
        return .Landscape;
    }

    // MARK: - Playback setup

    func setupPlaybackForURL(URL: NSURL) {
        /*
         Sets up player item and adds video output to it.
         The tracks property of an asset is loaded via asynchronous key value loading, to access the preferred transform of a video track used to orientate the video while rendering.
         After adding the video output, we request a notification of media change in order to restart the CADisplayLink.
         */

        // Remove video output from old item, if any.
        if let item = _player.currentItem {
            item.removeOutput(self.videoOutput)
        }

        let item = AVPlayerItem(URL: URL)
        let asset = item.asset

        asset.loadValuesAsynchronouslyForKeys(["tracks"], completionHandler: { () -> Void in
            if asset.statusOfValueForKey("tracks", error: nil) == .Loaded {
                let tracks = asset.tracksWithMediaType(AVMediaTypeVideo)
                if tracks.count > 0 {
                    // Choose the first video track.
                    let videoTrack = tracks[0]
                    videoTrack.loadValuesAsynchronouslyForKeys(["preferredTransform"], completionHandler: {
                        if videoTrack.statusOfValueForKey("preferredTransform", error: nil) == .Loaded {
                            let preferredTransform = videoTrack.preferredTransform

                            /*
                             The orientation of the camera while recording affects the orientation of the images received from an AVPlayerItemVideoOutput. Here we compute a rotation that is used to correctly orientate the video.
                             */
                            self.playerView.preferredRotation = -1 * atan2(Float(preferredTransform.b), Float(preferredTransform.a))

                            self.addDidPlayToEndTimeNotificationForPlayerItem(item)

                            dispatch_async(dispatch_get_main_queue()) { [unowned self] in
                                item.addOutput(self.videoOutput)
                                self._player.replaceCurrentItemWithPlayerItem(item)
                                self.videoOutput.requestNotificationOfMediaDataChangeWithAdvanceInterval(ONE_FRAME_DURATION)
                                self._player.play()
                            }
                        }
                    })
                }
            }

        })
    }

    func stopLoadingAnimationAndHandleError(error: NSError?) {
        if let error = error {
            let cancelButtonTitle = NSLocalizedString("OK", comment: "Cancel button title for animation load error")
            let alertView = UIAlertView(title: error.localizedDescription, message: error.localizedFailureReason ?? "", delegate: nil, cancelButtonTitle: cancelButtonTitle)
            alertView.show()
        }
    }

    override func observeValueForKeyPath(keyPath: String?, ofObject object: AnyObject?, change: [String : AnyObject]?, context: UnsafeMutablePointer<Void>) {
        if context == AVPlayerItemStatusContext {
            if let rawValue = change?[NSKeyValueChangeNewKey] as? Int, let status = AVPlayerStatus(rawValue: rawValue) {
                switch status {
                case .Unknown:
                    break
                case .ReadyToPlay:
                    if let rect = _player.currentItem?.presentationSize {
                        self.playerView.presentationRect = rect
                    }
                case .Failed:
                    if let error = _player.currentItem?.error {
                        self.stopLoadingAnimationAndHandleError(error)
                    }
                }
            }
        } else {
            super.observeValueForKeyPath(keyPath, ofObject: object, change: change, context: context)
        }

    }

    func addDidPlayToEndTimeNotificationForPlayerItem(item: AVPlayerItem) {
        if _notificationToken != nil {
            _notificationToken = nil
        }

        /*
         Setting actionAtItemEnd to None prevents the movie from getting paused at item end. A very simplistic, and not gapless, looped playback.
         */
        _player.actionAtItemEnd = .None;
        _notificationToken = NSNotificationCenter.defaultCenter().addObserverForName(AVPlayerItemDidPlayToEndTimeNotification, object: item, queue: NSOperationQueue.mainQueue(), usingBlock: { [unowned self] (note: NSNotification) -> Void in
                // Simple item playback rewind.
                self._player.currentItem?.seekToTime(kCMTimeZero)
            })
    }

    func syncTimeLabel() {
        var seconds = CMTimeGetSeconds(_player.currentTime())
        if !isfinite(seconds) {
            seconds = 0
        }

        var secondsInt = Int(round(seconds))
        let minutes = secondsInt / 60
        secondsInt = secondsInt % 60

        self.currentTime.textColor = UIColor(white: 1.0, alpha: 1.0)
        self.currentTime.textAlignment = .Center

        self.currentTime.text = String(format: "%.2i:%.2i", minutes, secondsInt)
    }

    func addTimeObserverToPlayer() {
        /*
         Adds a time observer to the player to periodically refresh the time label to reflect current time.
         */
        guard _timeObserver == nil else {
            return
        }

        /*
         Unown self to ensure that a strong reference cycle is not formed between the view controller, player and notification block.
         */
        _timeObserver = _player.addPeriodicTimeObserverForInterval(CMTimeMakeWithSeconds(1, 10), queue: dispatch_get_main_queue(), usingBlock: { [unowned self] (time: CMTime) -> Void in
                self.syncTimeLabel()
            })
    }

    func removeTimeObserverFromPlayer() {
        if _timeObserver != nil {
            _player.removeTimeObserver(_timeObserver)
            _timeObserver = nil
        }
    }

    // MARK: - CADisplayLink Callback

    func displayLinkCallback(sender: CADisplayLink?) {
        guard let sender = sender else {
            return
        }

        /*
         The callback gets called once every Vsync.
         Using the display link's timestamp and duration we can compute the next time the screen will be refreshed, and copy the pixel buffer for that time
         This pixel buffer can then be processed and later rendered on screen.
         */
        var outputItemTime = kCMTimeInvalid

        // Calculate the nextVsync time which is when the screen will be refreshed next.
        let nextVSync = sender.timestamp + sender.duration

        outputItemTime = self.videoOutput.itemTimeForHostTime(nextVSync)

        if self.videoOutput.hasNewPixelBufferForItemTime(outputItemTime) {
            if let pixelBuffer = self.videoOutput.copyPixelBufferForItemTime(outputItemTime, itemTimeForDisplay: nil) {
                self.playerView.displayPixelBuffer(pixelBuffer)
            }
        }
    }

    // MARK: - AVPlayerItemOutputPullDelegate

    func outputMediaDataWillChange(sender: AVPlayerItemOutput) {
        // Restart display link.
        self.displayLink.paused = false
    }

    // MARK: - Image Picker Controller Delegate

    func imagePickerController(picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [String : AnyObject]) {
        if UIDevice.currentDevice().userInterfaceIdiom == .Pad {
            self.popover?.dismissPopoverAnimated(true)
        } else {
            self.dismissViewControllerAnimated(true, completion: nil)
        }

        if _player.currentItem == nil {
            self.lumaLevelSlider.enabled = true
            self.chromaLevelSlider.enabled = true
            self.playerView.setupGL()
        }

        // Time label shows the current time of the item.
        if self.timeView.hidden {
            self.timeView.layer.backgroundColor = UIColor(white: 0.0, alpha: 0.3).CGColor
            self.timeView.layer.cornerRadius = 5.0
            self.timeView.layer.borderColor = UIColor(white: 1.0, alpha: 0.15).CGColor
            self.timeView.layer.borderWidth = 1.0
            self.timeView.hidden = false
            self.currentTime.hidden = false
        }

        if let url = info[UIImagePickerControllerReferenceURL] as? NSURL {
            self.setupPlaybackForURL(url)
        }

        picker.delegate = nil;
    }

    func imagePickerControllerDidCancel(picker: UIImagePickerController) {
        self.dismissViewControllerAnimated(true, completion:nil)

        // Make sure our playback is resumed from any interruption.
        if let item = _player.currentItem {
            self.addDidPlayToEndTimeNotificationForPlayerItem(item)
        }

        self.videoOutput.requestNotificationOfMediaDataChangeWithAdvanceInterval(ONE_FRAME_DURATION)
        _player.play()

        picker.delegate = nil
    }

    // MARK: - Popover Controller Delegate

    func popoverControllerDidDismissPopover(popoverController: UIPopoverController) {
        // Make sure our playback is resumed from any interruption.
        if let item = _player.currentItem {
            self.addDidPlayToEndTimeNotificationForPlayerItem(item)
        }
        self.videoOutput.requestNotificationOfMediaDataChangeWithAdvanceInterval(ONE_FRAME_DURATION)
        _player.play()
    
        self.popover?.delegate = nil
    }
    
    // MARK: - Gesture recognizer delegate
    
    func gestureRecognizer(gestureRecognizer: UIGestureRecognizer, shouldReceiveTouch touch:UITouch) -> Bool {
        return touch.view == self.view
    }
}
