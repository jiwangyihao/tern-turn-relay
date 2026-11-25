// Standalone macOS behavior tests. No real clipboard, dialog, workspace delivery,
// credential, or host is used. Importing the implementation keeps its seams private.
#import "../native/src/pair_import.m"
#import <CoreImage/CoreImage.h>

static void check(BOOL passed, int line) {
    if (!passed) @throw [NSException exceptionWithName:@"Check" reason:@"test failed"
        userInfo:@{@"line": @(line)}];
}
#define CHECK(...) check((__VA_ARGS__), __LINE__)

static NSString *const first = @"tern://pair?v=1&name=Lab-A&user=tester&fp=SHA256%3Aab%2B%2F%3D&alt=one&alt=two&literal=a+b&key=fixture-only";
static NSString *const second = @"tern://pair?name=Lab-B&key=other-fixture";
static NSString *const other = @"https://example.invalid/not-an-invitation";

static CGImageRef makeQR(CIContext *ci, NSString *payload) CF_RETURNS_RETAINED {
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setValue:[payload dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    [filter setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *output = filter.outputImage;
    CHECK(output != nil);
    return [ci createCGImage:output fromRect:output.extent];
}

// Draw integer-sized black/white modules, with a quiet zone around each code.
static NSURL *writeFixture(NSURL *dir, NSString *name, NSArray<NSString *> *payloads,
                           size_t width, size_t height, BOOL jpeg, NSInteger orientation) {
    CGColorSpaceRef color = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(NULL, width, height, 8, width, color, kCGImageAlphaNone);
    CGColorSpaceRelease(color);
    CHECK(ctx != NULL);
    CGContextSetGrayFillColor(ctx, 1, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, width, height));
    CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
    if (orientation == kCGImagePropertyOrientationUpMirrored) {
        CGContextTranslateCTM(ctx, width, 0);
        CGContextScaleCTM(ctx, -1, 1);
    }
    if (payloads.count) {
        CIContext *ci = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}];
        size_t tile = width / payloads.count;
        for (NSUInteger i = 0; i < payloads.count; ++i) {
            CGImageRef qr = makeQR(ci, payloads[i]);
            CHECK(qr != NULL);
            size_t modules = CGImageGetWidth(qr);
            size_t pixels = modules * (MIN(tile, height) / (modules + 8));
            CHECK(pixels > 0);
            CGContextDrawImage(ctx, CGRectMake(i * tile + (tile - pixels) / 2, (height - pixels) / 2, pixels, pixels), qr);
            CGImageRelease(qr);
        }
    }
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CHECK(image != NULL);
    NSURL *url = [dir URLByAppendingPathComponent:name];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)url,
        jpeg ? CFSTR("public.jpeg") : CFSTR("public.png"), 1, NULL);
    CHECK(dest != NULL);
    NSDictionary *options = @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @0.97,
                              (__bridge NSString *)kCGImagePropertyOrientation: @(orientation)};
    CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef)options);
    BOOL written = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    CGImageRelease(image);
    CHECK(written);
    return url;
}

static NSArray<NSString *> *readFixture(NSURL *url) {
    int status = -1;
    NSArray *decoded = decodeImage(url, &status);
    CHECK(decoded != nil);
    return decoded;
}

static void imageTests(NSURL *dir) {
    ChooseInvite noChoice = ^NSInteger(NSArray *titles) { CHECK(NO); return -1; };
    DeliverInvite noDelivery = ^BOOL(NSURL *url) { CHECK(NO); return NO; };
    DeliverInvite exact = ^BOOL(NSURL *url) { CHECK([url.absoluteString isEqualToString:first]); return YES; };
    NSURL *png = writeFixture(dir, @"single.png", @[first], 384, 384, NO, 1);
    CHECK(submitCandidates(readFixture(png), NoInvite, noChoice, exact) == HandedOff);
    NSURL *jpeg = writeFixture(dir, @"oriented.jpg", @[first], 384, 384, YES, kCGImagePropertyOrientationUpMirrored);
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)jpeg, NULL);
    CHECK(source != NULL);
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    CFRelease(source);
    CHECK([properties[(__bridge NSString *)kCGImagePropertyOrientation] integerValue] == kCGImagePropertyOrientationUpMirrored);
    CHECK(submitCandidates(readFixture(jpeg), NoInvite, noChoice, exact) == HandedOff);

    NSURL *both = writeFixture(dir, @"two.png", @[first, second], 768, 384, NO, 1);
    NSArray *decoded = readFixture(both);
    CHECK([[NSSet setWithArray:decoded] isEqual:[NSSet setWithArray:@[first, second]]]);
    CHECK(submitCandidates(decoded, NoInvite, ^NSInteger(NSArray *titles) {
        CHECK(titles.count == 2);
        for (NSUInteger i = 0; i < titles.count; ++i)
            if ([titles[i] containsString:@"Lab-A"]) return (NSInteger)i;
        CHECK(NO); return -1;
    }, exact) == HandedOff);
    CHECK(submitCandidates(decoded, NoInvite, ^NSInteger(NSArray *titles) { return -1; }, noDelivery) == Cancelled);

    NSURL *unrelated = writeFixture(dir, @"ordinary.png", @[other], 384, 384, NO, 1);
    NSArray *ordinary = readFixture(unrelated);
    CHECK([ordinary containsObject:other]);
    CHECK(submitCandidates(ordinary, NoInvite, noChoice, noDelivery) == NoInvite);
    NSURL *blank = writeFixture(dir, @"empty.png", @[], 128, 128, NO, 1);
    CHECK(submitCandidates(readFixture(blank), NoInvite, noChoice, noDelivery) == NoInvite);

    NSURL *bad = [dir URLByAppendingPathComponent:@"bad.png"];
    CHECK([[@"not an image" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:bad atomically:NO]);
    int status;
    CHECK(!decodeImage(bad, &status) && status == InvalidImage);
    NSURL *wide = writeFixture(dir, @"wide.png", @[], maxDimension + 1, 1, NO, 1);
    CHECK(!decodeImage(wide, &status) && status == ImageTooLarge);
    // A sparse file exercises the byte budget without allocating a large fixture.
    CHECK(truncate(bad.fileSystemRepresentation, maxBytes + 1) == 0);
    CHECK(!decodeImage(bad, &status) && status == ImageTooLarge);
    NSURL *link = [dir URLByAppendingPathComponent:@"link.png"];
    CHECK(symlink(png.fileSystemRepresentation, link.fileSystemRepresentation) == 0);
    CHECK(!decodeImage(link, &status) && status == InvalidImage);
    CHECK(!decodeImage(dir, &status) && status == InvalidImage);
}

static void routeTests(void) {
    for (NSString *raw in @[@"", other, @"https://pair?a=b", @"tern://pair.example", @"tern://user@pair?x",
            @"tern://pair@example.invalid?x", @"tern://pair:443", @"tern://pair:", @"tern://%70air", @"tern://pair/other",
            @"tern://pair#fragment", @"tern://pair?x=raw space", @"tern://pair?x=%0D%0a", @"tern://pair?x=%00",
            @"tern://pair?x=%Q1", @"tern://pair?x=%", @"tern://pair?x=\n", @"tern://pair?x=\\foo"])
        CHECK(!inviteURL(raw));
    for (NSString *raw in @[@"tern://pair", @"tern://pair/?future=1", @"TERN://PAIR?x=2", first])
        CHECK([inviteURL(raw).absoluteString isEqualToString:raw]);
    NSString *longValue = [@"tern://pair?x=" stringByPaddingToLength:16385 withString:@"a" startingAtIndex:0];
    CHECK(!inviteURL(longValue));

    ChooseInvite noChoice = ^NSInteger(NSArray *titles) { CHECK(NO); return -1; };
    DeliverInvite noDelivery = ^BOOL(NSURL *url) { CHECK(NO); return NO; };
    CHECK(submitCandidates(@[other], UnsupportedInvite, noChoice, noDelivery) == UnsupportedInvite);
    __block NSMutableArray *delivered = [NSMutableArray array];
    int result = submitCandidates(@[other, first, first], NoInvite, noChoice, ^BOOL(NSURL *url) {
        [delivered addObject:url.absoluteString]; return NO;
    });
    CHECK(result == DeliveryFailed && [delivered isEqual:@[first]]);

    NSString *leaking = @"tern://pair?%6bey=lab-secret&name=xlab-secret&user=bad%2Fname";
    NSString *copied = @"tern://pair?name=lab-secret&user=GoodUser";
    CHECK(submitCandidates(@[leaking, copied], NoInvite, ^NSInteger(NSArray *titles) {
        CHECK([titles isEqual:@[@"QR 1", @"QR 2 · GoodUser"]]);
        return NSNotFound;
    }, noDelivery) == Cancelled);
    NSString *split = @"tern://pair?key=12345678&name=%201234&user=5678%20";
    CHECK(submitCandidates(@[split, copied], NoInvite, ^NSInteger(NSArray *titles) {
        CHECK([titles.firstObject isEqualToString:@"QR 1"]);
        return NSNotFound;
    }, noDelivery) == Cancelled);
}

static void choiceTests(void) {
    // Build the real picker control, but never show/activate an app or window.
    [NSApplication sharedApplication];
    NSButton *submit = [NSButton new];
    TernChoice *choice = [[TernChoice alloc] initWithTitles:@[@"QR 1", @"QR 2"] submit:submit];
    CHECK(choice.indexOfSelectedItem == 0 && !submit.enabled);
    [choice selectItemAtIndex:2];
    [choice sendAction:choice.action to:choice.target];
    CHECK(submit.enabled && choice.indexOfSelectedItem - 1 == 1);
    [choice selectItemAtIndex:0];
    [choice sendAction:choice.action to:choice.target];
    CHECK(!submit.enabled);
}

int main(void) {
    @autoreleasepool {
        NSString *template = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tern-pair-test.XXXXXX"];
        char *path = strdup(template.fileSystemRepresentation);
        if (!path || !mkdtemp(path)) { free(path); return 1; }
        NSURL *dir = [NSURL fileURLWithFileSystemRepresentation:path isDirectory:YES relativeToURL:nil];
        free(path);
        int result = 0;
        @try { routeTests(); choiceTests(); imageTests(dir); }
        @catch (NSException *exception) {
            // Report only a test location, never URLs, code payloads or framework error text.
            fprintf(stderr, "macOS importer test failed (line %d)\n", [exception.userInfo[@"line"] intValue]);
            result = 1;
        } @finally {
            if (![NSFileManager.defaultManager removeItemAtURL:dir error:NULL]) result = 1;
        }
        if (!result) puts("macOS pairing importer tests passed");
        return result;
    }
}
