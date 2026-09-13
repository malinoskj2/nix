import com.intellij.ide.ui.UISettings
import com.intellij.openapi.diagnostic.Logger
import groovy.transform.Field

import javax.swing.JComponent
import javax.swing.JFrame
import javax.swing.RepaintManager
import javax.swing.SwingUtilities
import javax.swing.UIManager
import java.awt.Color
import java.awt.Component
import java.awt.Container
import java.awt.Frame

@Field final Color GLASS = new Color(0x11, 0x11, 0x1b, 0x8c)
@Field final Color CLEAR = new Color(0, 0, 0, 0)
@Field final Logger log = Logger.getInstance('glass-header')

SwingUtilities.invokeLater {
    try {
        useGlassToolbarColors()
        paintStraightIntoWindowSurfaces()
        turnOffProjectGradient()
        glazeOpenWindows()
        log.info 'glass-header applied'
    } catch (Throwable t) {
        log.warn 'glass-header failed', t
    }
}

/**
 * Points the theme's main toolbar colors at {@code GLASS}, so the header gets the glass color
 * whenever it asks the theme for its background, focused or not.
 */
void useGlassToolbarColors() {
    UIManager.put('MainToolbar.background', GLASS)
    UIManager.put('MainToolbar.inactiveBackground', GLASS)
}

/**
 * Replaces Swing's paint manager with the plain {@code RepaintManager.PaintManager}.
 * The IDE forces {@code swing.bufferPerWindow=true}, whose per-window back buffer drops alpha
 * on Wayland; the plain manager paints straight into the window's ARGB surface instead.
 */
void paintStraightIntoWindowSurfaces() {
    RepaintManager
     .currentManager((Component) null)
     .setPaintManager(new RepaintManager.PaintManager())
}

/**
 * Turns off the project-color gradient, which paints opaque over the header.
 * This changes a persisted UI setting, so it only does anything on the first run.
 */
void turnOffProjectGradient() {
    def settings = UISettings.instance

    if (settings.differentiateProjects) {
        settings.differentiateProjects = false
        settings.fireUISettingsChanged()
    }
}

/**
 * Glazes every JFrame currently open in the IDE.
 */
void glazeOpenWindows() {
    Frame.frames
      .grep(JFrame)
      .each { glaze(it) }
}

/**
 * Makes one window's main header translucent: clears the window background, stops the header
 * and its children from painting opaque, and gives the header the glass color.
 *
 * @param frame the window to glaze; left untouched if it has no {@code ToolbarFrameHeader}
 */
void glaze(JFrame frame) {
    def header = descendantsOf(frame.rootPane).find { it.class.simpleName == 'ToolbarFrameHeader' }
    if (!header) return

    makeTransparent(frame)
    descendantsOf(header).grep(JComponent).each { it.opaque = false }
    header.background = GLASS
    frame.repaint()
}

/**
 * Sets a window's background to fully transparent.
 * {@code Frame.setBackground} rejects alpha on decorated frames, so this writes the private
 * {@code background} field directly.
 *
 * @param frame the window to make transparent
 */
void makeTransparent(Frame frame) {
    Component
      .getDeclaredField('background')
      .tap { accessible = true }
      .set(frame, CLEAR)
}

/**
 * Lists a component and everything nested inside it, depth-first.
 *
 * @param component the root of the tree to walk
 * @return {@code component} followed by all of its descendants
 */
List<Component> descendantsOf(Component component) {
    def children = component instanceof Container ? component.components as List : []
    [component] + children.collectMany { descendantsOf(it) }
}
