// Renders a preview sheet of an app bundle's icon the way macOS draws it.
// Usage: preview <App.app> <out.png>
// Built and run by preview.sh. Uses the private IconServices framework, so it
// is a dev tool only; nothing in the app links it.
//
// Sheet: the light icon at 1024 px with the same icon at its real 32 and 16 px
// size beside it, then a row with the light, dark and two clear looks at 256 px.
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <objc/message.h>

static CGImageRef Render(id icon, CGFloat px, NSUInteger appearance, NSUInteger variant) {
    id d = ((id (*)(id, SEL, CGSize, CGFloat))objc_msgSend)(
        [NSClassFromString(@"ISImageDescriptor") alloc], sel_registerName("initWithSize:scale:"),
        CGSizeMake(px, px), 1.0);
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(d, sel_registerName("setAppearance:"), appearance);
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(d, sel_registerName("setAppearanceVariant:"), variant);
    ((id (*)(id, SEL, id))objc_msgSend)(icon, sel_registerName("prepareImageForDescriptor:"), d);
    return ((CGImageRef (*)(id, SEL, id))objc_msgSend)(icon, sel_registerName("CGImageForDescriptor:"), d);
}

static void Label(NSString *text, CGFloat x, CGFloat y) {
    [text drawAtPoint:NSMakePoint(x, y)
       withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:22 weight:NSFontWeightMedium],
                        NSForegroundColorAttributeName: [NSColor colorWithWhite:0.25 alpha:1]}];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) { fprintf(stderr, "usage: preview <App.app> <out.png>\n"); return 2; }
        if (!dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_NOW)) return 1;
        id icon = ((id (*)(id, SEL, id))objc_msgSend)(
            [NSClassFromString(@"ISBundleIcon") alloc], sel_registerName("initWithBundleURL:"),
            [NSURL fileURLWithPath:@(argv[1])]);

        const CGFloat pad = 48, big = 1024, small = 256;
        const CGFloat W = pad + big + pad + 32 + pad + 16 + pad;
        const CGFloat H = pad + big + pad + 30 + small + 30 + pad;
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)W pixelsHigh:(NSInteger)H bitsPerSample:8
            samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
        [[NSColor colorWithWhite:0.9 alpha:1] setFill];
        NSRectFill(NSMakeRect(0, 0, W, H));

        CGFloat top = H - pad;
        CGContextDrawImage(cg, CGRectMake(pad, top - big, big, big), Render(icon, big, 0, 0));
        CGFloat x = pad + big + pad;
        CGContextDrawImage(cg, CGRectMake(x, top - 32, 32, 32), Render(icon, 32, 0, 0));
        Label(@"32", x, top - 32 - 30);
        x += 32 + pad;
        CGContextDrawImage(cg, CGRectMake(x, top - 16, 16, 16), Render(icon, 16, 0, 0));
        Label(@"16", x - 4, top - 16 - 30);

        // appearance 0 = light, 1 = dark; variant 0 = default, 2 and 3 = the clear looks (the tinted look is built from the same mono layers).
        NSUInteger looks[4][2] = {{0, 0}, {1, 0}, {0, 2}, {1, 3}};
        NSString *names[4] = {@"light", @"dark", @"clear light", @"clear dark"};
        CGFloat rowTop = top - big - pad - 30;
        for (int i = 0; i < 4; i++) {
            CGFloat lx = pad + i * (small + pad);
            Label(names[i], lx, rowTop + 2);
            CGContextDrawImage(cg, CGRectMake(lx, rowTop - small, small, small),
                               Render(icon, small, looks[i][0], looks[i][1]));
        }
        [NSGraphicsContext restoreGraphicsState];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        return [png writeToFile:@(argv[2]) atomically:YES] ? 0 : 1;
    }
}
