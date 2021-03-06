
{
  Handlers
  removeNode
  removeChildren
  loadSheet
  removeSheet
  createElement
  superdomains
  isSuperdomain
  defaults
} = require 'utils'
{ overlayQueue } = require 'ui/overlay-queue'

{ windows } = require 'windows'
{ tabs } = require 'tabs'
{ memo } = require 'request-memo'
{ manager } = require 'ruleset/manager'
{ DomainDomainTypeRS } = require 'ruleset/code-ruleset'

{ Color } = require 'color'
{ prefs } = require 'prefs'

{ l10n } = require 'l10n'


WILDCARD_TYPE = DomainDomainTypeRS::WILDCARD_TYPE


POSITIVE_COLOR_PREF = 'ui.popup.positiveBackgroundColor'
NEGATIVE_COLOR_PREF = 'ui.popup.negativeBackgroundColor'


colorGetter = (c) -> new Color c
colorSetter = (c) -> c.toCssString()
prefs.define POSITIVE_COLOR_PREF,
  default: '#0f02'
  get: colorGetter
  set: colorSetter
prefs.define NEGATIVE_COLOR_PREF,
  default: '#f002'
  get: colorGetter
  set: colorSetter

positiveBackgroundColor = prefs.get POSITIVE_COLOR_PREF
prefs.onChange POSITIVE_COLOR_PREF, ->
  positiveBackgroundColor = prefs.get POSITIVE_COLOR_PREF
negativeBackgroundColor = prefs.get NEGATIVE_COLOR_PREF
prefs.onChange NEGATIVE_COLOR_PREF, ->
  negativeBackgroundColor = prefs.get NEGATIVE_COLOR_PREF


class Button
  create: (doc, description) ->
    {
      id
      label
      tooltiptext
      classList
      disabled
      click
      appendTo
      style
    } = description
    classList = classList or []

    lbl = createElement doc, 'label',
      class: 'policeman-popup-button-label'
      value: label
      style: 'cursor: inherit;'
    if tooltiptext
      lbl.setAttribute 'tooltiptext', tooltiptext

    innerBox = createElement doc, 'vbox',
      class: 'policeman-popup-button-box'
    box = createElement doc, 'vbox',
      class: (classList.concat ['policeman-popup-button']).join(' ')
      disabled: if disabled then 'true' else 'false'
      style: style or ''
    if id
      box.setAttribute 'id', id
    if click
      box.addEventListener 'click', do (that=@) -> ->
        return if that.disabled @
        click.apply @, arguments

    box.appendChild innerBox
    innerBox.appendChild lbl

    appendTo.appendChild box if appendTo

    return box

  disable: (btn) -> btn.setAttribute('disabled', 'true')
  enable: (btn) -> btn.setAttribute('disabled', 'false')
  disabled: (btn) -> btn.getAttribute('disabled') == 'true'

  setData: (btn, str) -> btn.setAttribute('data', str)
  getData: (btn) -> btn.getAttribute('data')

  setLabel: (btn, str) ->
    lbl = btn.getElementsByClassName('policeman-popup-button-label')[0]
    lbl.setAttribute 'value', str


class LinkButton extends Button
  create: (doc, description) ->
    defaults description, 'style', ''
    description.style += 'cursor: pointer;'
    btn = super doc, description
    reuse = not ('reuse' of description) or description.reuse
    if description.url
        btn.addEventListener 'click', ->
          tabs.open description.url, reuse
          popup.hide(doc)
    return btn


class DataRotationButton extends Button
  create: (doc, description) ->
    {
      valuesLabels
      click: inferiorClick
    } = description
    i = 0
    defaults description, 'label', valuesLabels[i][1]
    description.click = do (that=@) -> (e) ->
      if e.button == 0 # left
        i += 1
        i = 0 if i >= valuesLabels.length
      else if e.button == 2 # right
        i -= 1
        i = valuesLabels.length-1 if i < 0
      that.setData @, valuesLabels[i][0]
      that.setLabel @, valuesLabels[i][1]
      inferiorClick.apply @, arguments if inferiorClick
    defaults description, 'classList', []
    description.classList.push 'policeman-popup-value-rotation-button'
    btn = Button::create doc, description
    @setData btn, valuesLabels[i][0]
    return btn


class RadioButton extends Button
  create: (doc, description) ->
    defaults description, 'classList', []
    description.classList.push 'policeman-popup-radio-button'
    btn = super doc, description
    if 'data' of description
      @setData btn, description.data
    @unselect btn
    return btn

  select: (btn) -> btn.setAttribute('selected', 'true')
  unselect: (btn) -> btn.setAttribute('selected', 'false')
  selected: (btn) -> btn.getAttribute('selected') == 'true'


class CheckButton extends Button
  create: (doc, description) ->
    defaults description, 'classList', []
    description.classList.push 'policeman-popup-check-button'
    click = description.click
    description.click = do (that=@) -> ->
      that.toggle @
      click.call @, arguments
    btn = super doc, description
    if description.checked
      @check btn
    else
      @uncheck btn
    return btn

  check: (btn) -> btn.setAttribute('checked', 'true')
  uncheck: (btn) -> btn.setAttribute('checked', 'false')
  checked: (btn) -> btn.getAttribute('checked') == 'true'
  toggle: (btn) ->
    if @checked btn
      @uncheck btn
    else
      @check btn


class ContainerPopulation
  constructor: (@_containerId) ->
  populate: (doc) ->
  purge: (doc) ->
    removeChildren doc.getElementById @_containerId
  update: (doc) ->
    @purge doc
    @populate doc


class RadioButtons extends ContainerPopulation
  constructor: (containerId, @selectedData=null) ->
    super containerId
    @onSelection = new Handlers

  _createButton: (doc, description) ->
    btn = RadioButton::create doc, description
    btn.addEventListener 'click', do (group=this) -> ->
      return if RadioButton::disabled @
      group._select @
    return btn

  _select: (btn) ->
    doc = btn.ownerDocument
    for b in doc.getElementById(@_containerId).childNodes
      RadioButton::unselect b
    RadioButton::select btn
    @selectedData = RadioButton::getData btn
    @onSelection.execute btn, @selectedData, @


class DomainSelectionButtons extends RadioButtons
  class DomainTree
    constructor: ->
      # noname root domain
      @root = {label: '', hits: 0, directHits: 0, descendantDirectHits: 0, children: []}
    hit: (domain) ->
      tree = [@root]
      labels = domain.split('.').concat ''
      track = []
      while (label = labels.pop()) != undefined
        target = tree.find (n) -> n.label == label # find node for label
        if not target # or create it
          target = {label: label, hits: 0, directHits: 0, descendantDirectHits: 0, children: []}
          tree.push target
        target.hits += 1
        if labels.length
          track.push target
          tree = target.children
        else
          if not target.directHits
            while (ancestor = track.pop()) != undefined
              ancestor.descendantDirectHits += 1
          target.directHits += 1
      return
    noop = ->
    walkIn: (in_, tree=[@root]) ->
      for n in tree
        in_ n, @walkIn(in_, n.children)
    walk: (pre, post=noop, tree=[@root]) ->
      for n in tree
        skip = pre n
        if not skip
          @walk pre, post, n.children
        post n
    OMIT_DESCENDANTS_THRESHOLD = 4
    OMIT_DESCENDANTS_DEPTH = 2 # do not omit second and higher level domains
    shouldOmitDescendants = (node, depth) ->
      (node.descendantDirectHits > OMIT_DESCENDANTS_THRESHOLD) \
      and (depth > OMIT_DESCENDANTS_DEPTH)
    getHitDomains: ->
      reducedTree = [root = {domain: '', hits: @root.hits, children: []}]

      nodesStack = [root]
      labels = []
      @walk ((node) ->
        labels.unshift node.label
        depth = labels.length
        omit = shouldOmitDescendants node, depth
        if node.directHits or omit
          rnode = {
            domain: labels.join('.').slice(0, -1) # slice off trailing '.'
            hits: node.hits
            children: []
          }
          nodesStack[0].children.push rnode
          nodesStack.unshift rnode if not omit
        return omit
      ), ((node) ->
        depth = labels.length
        if node.directHits and not shouldOmitDescendants node, depth
          nodesStack.shift()
        labels.shift()
      )

      @walkIn ((n) -> n.children.sort (a, b) -> b.hits - a.hits), reducedTree

      result = []
      indentation = 0
      @walk ((n) ->
        indentation += 1
        result.push [
          indentation,
          n.domain,
        ]
        return false
      ), ((n) ->
        indentation -= 1
      ), root.children

      return result

  _createButton: (doc, description) ->
    { allowHits, rejectHits } = description
    allowRatio = allowHits/(allowHits + rejectHits)

    defaults description, 'label', description.domain
    defaults description, 'data', description.domain
    defaults description, 'tooltiptext', l10n('popup_domain.tip',
                    allowHits, rejectHits, Math.round allowRatio*100)
    defaults description, 'style', ''

    description.style += "
      background: #{
        positiveBackgroundColor.mix(
          negativeBackgroundColor, allowRatio
        ).toCssString()
      };
      margin-left: #{ description.indentation or 0 }em;
    "

    btn = super doc, description

    return btn

  populate: (doc) ->
    domainToStats = Object.create null
    tree = new DomainTree
    for [o, d, c, decision] in memo.getByTab tabs.getCurrent()
      continue if decision is null
      domain = @_chooseDomain o, d, c, decision
      continue if not domain
      tree.hit domain
      stat = if decision then 'allow' else 'reject'
      for d in superdomains domain
        defaults domainToStats, d, {allow:0, reject:0}
        domainToStats[d][stat] += 1

    return if not domainToStats['']

    fragment = doc.createDocumentFragment()

    selectionRestored = no

    fragment.appendChild anyBtn = @_createButton doc,
      label: l10n 'popup_any_domain'
      domain: ''
      allowHits: domainToStats[''].allow
      rejectHits: domainToStats[''].reject

    for [indentation, domain] in tree.getHitDomains()
      fragment.appendChild btn = @_createButton doc,
        domain: domain
        allowHits: domainToStats[domain].allow
        rejectHits: domainToStats[domain].reject
        indentation: indentation
      if (not selectionRestored) and (@selectedData == domain)
        @_select btn
        selectionRestored = true

    if not selectionRestored
      @_select anyBtn

    doc.getElementById(@_containerId).appendChild fragment

  _chooseDomain: -> throw new Error 'Subclass must supply "_chooseDomain" method.'


originSelection = new (class extends DomainSelectionButtons
  _chooseDomain: (o, d, c, decision) ->
    if (o.schemeType == d.schemeType == 'web')
      return o.host
    else
      return false

  populate: (doc) ->
    location = tabs.getCurrent().linkedBrowser.contentWindow.location
    @selectedData = location.hostname
    super doc

) 'policeman-popup-origins-container'

destinationSelection = new (class extends DomainSelectionButtons
  _chooseDomain: (o, d, c, decision) ->
    if (o.schemeType == d.schemeType == 'web') \
    and (isSuperdomain originSelection.selectedData, o.host)
      return d.host
    else
      return false
) 'policeman-popup-destinations-container'


SUPPORTED_TYPES = [
  'IMAGE',
  'MEDIA',
  'STYLESHEET',
  'SCRIPT',
  'OBJECT',
  'SUBDOCUMENT',
]

localizeTypeLookup =
  IMAGE: l10n 'popup_type_image'
  MEDIA: l10n 'popup_type_media'
  STYLESHEET: l10n 'popup_type_stylesheet'
  SCRIPT: l10n 'popup_type_script'
  SUBDOCUMENT: l10n 'popup_type_subdocument'
  OBJECT: l10n 'popup_type_object'
localizeTypeLookup[WILDCARD_TYPE] = l10n 'popup_type_wildcard'
localizeType = (t) -> localizeTypeLookup[t]
# also check popup_filter_* properties when changing that ^^^


categorizeRequest = (o, d, c) ->
  if c.contentType in SUPPORTED_TYPES
    return c.contentType
  return 'OTHER'

class FilterButtons extends RadioButtons
  constructor: (containerId) ->
    super containerId, 'NONE'
  populate: (doc, decision) ->
    stats = { ALL:0, OTHER:0 }
    stats[t] = 0 for t in SUPPORTED_TYPES
    for [o, d, c, decision_] in memo.getByTab tabs.getCurrent()
      if  (decision_ == decision) \
      and (o.schemeType == d.schemeType == 'web') \
      and (isSuperdomain originSelection.selectedData, o.host) \
      and (isSuperdomain destinationSelection.selectedData, d.host)
        category = categorizeRequest o, d, c
        stats[category] += 1
        stats.ALL += 1

    filters = doc.createDocumentFragment()
    for value in ['ALL'].concat(SUPPORTED_TYPES).concat(['OTHER'])
      label = "popup_filter_#{value.toLowerCase()}"
      filters.appendChild btn = @_createButton doc,
        label: l10n label, stats[value]
        data: value
        disabled: not stats[value]
      @_select btn if @selectedData == value

    doc.getElementById(@_containerId).appendChild filters

rejectedFilter = new (class extends FilterButtons
  populate: (doc) ->
    filters = doc.getElementById @_containerId
    filters.appendChild none = @_createButton doc,
      label: l10n 'popup_filter_rejected_none'
      data: 'NONE'
    @_select none if @selectedData == 'NONE'
    super doc, false
) 'policeman-popup-rejected-requests-filters-container'


allowedFilter = new (class extends FilterButtons
  populate: (doc) ->
    filters = doc.getElementById @_containerId
    filters.appendChild none = @_createButton doc,
      label: l10n 'popup_filter_allowed_none'
      data: 'NONE'
    @_select none if @selectedData == 'NONE'
    super doc, true
) 'policeman-popup-allowed-requests-filters-container'


class RequestList extends ContainerPopulation
  createItem: (doc, description) ->
    {
      origin
      destination
      context
      decision
    } = description

    originLbl = createElement doc, 'label',
      class: 'text-link policeman-popup-request-label policeman-popup-request-origin-label'
      value: origin.host
      tooltiptext: origin.spec
      href: origin.spec

    contextSummary = ""
    if context.nodeName
      contextSummary += \
        "#{ l10n('request_context_node') } #{ context.nodeName }\n"
    if context.contentType
      contextSummary += \
        "#{ l10n 'request_context_content_type' } #{ context.contentType }\n"
    if context.mime
      contextSummary += \
        "#{ l10n 'request_context_mime_type' } #{ context.mime }\n"
    if context.id
      contextSummary += \
        "#{ l10n 'request_context_id' } #{ context.id }\n"
    if context.className
      contextSummary += \
        "#{ l10n 'request_context_class_name' } #{ context.className }\n"
    arrowLbl = createElement doc, 'label',
      class: 'policeman-popup-request-label policeman-popup-request-arrow-label'
      value: l10n if decision then 'popup_arrow' else 'popup_arrow_with_stroke'
      tooltiptext: contextSummary

    destLbl = createElement doc, 'label',
      class: 'text-link policeman-popup-request-label policeman-popup-request-destination-label'
      value: destination.spec
      tooltiptext: destination.spec
      href: destination.spec
      crop: 'center'

    box = createElement doc, 'hbox',
      class: 'policeman-popup-request'

    box.appendChild originLbl
    box.appendChild arrowLbl
    box.appendChild destLbl

    return box

  requests: -> throw new Error "Subclass should supply 'requests' method."

  populate: (doc) ->
    fragment = doc.createDocumentFragment()
    for [o, d, c, decision] in @requests()
      fragment.appendChild @createItem doc,
        origin: o
        destination: d
        context: c
        decision: decision
    doc.getElementById(@_containerId).appendChild fragment

class FilteredRequestList extends RequestList
  constructor: (containerId, @filterButtons) ->
    super containerId
  requests: ->
    requests = memo.getByTab(tabs.getCurrent()).filter ([o, d, c]) ->
      (o.schemeType == d.schemeType == 'web') \
      and (isSuperdomain originSelection.selectedData, o.host) \
      and (isSuperdomain destinationSelection.selectedData, d.host)
    return requests if @filterButtons.selectedData == 'ALL'
    return requests.filter ([o, d, c, decision]) =>
      @filterButtons.selectedData == categorizeRequest(o, d, c)

allowedList = new (class extends FilteredRequestList
  requests: ->
    super().filter ([o,d,c,decision]) -> decision is true
) 'policeman-popup-allowed-requests-container', allowedFilter

rejectedList = new (class extends FilteredRequestList
  requests: ->
    super().filter ([o,d,c,decision]) -> decision is false
) 'policeman-popup-rejected-requests-container', rejectedFilter

class RulesetEditButtons extends ContainerPopulation
  constructor: (containerId, @_rulesetId) ->
    super containerId

  _createBasicRuleWidget: (doc, description) ->
    {
      tooltiptext
      classList
      origin
      destination
      decision
      type
    } = description
    classList = classList or []

    origin = origin or l10n 'popup_rule_any_domain'
    destination = destination or l10n 'popup_rule_any_domain'

    box = createElement doc, 'vbox',
      class: classList.join(' ') \
        + ' policeman-popup-rule' \
        + (if decision then ' policeman-popup-rule-allow' else '') \
        + (if decision == false then ' policeman-popup-rule-reject' else '')
    if tooltiptext
      box.setAttribute 'tooltiptext', tooltiptext

    subbox = createElement doc, 'vbox'

    lbl = createElement doc, 'label',
      class: 'policeman-popup-rule-label'
      value: l10n "popup_#{if decision then 'allow' else 'reject'}_rule", origin, destination, localizeType type

    subbox.appendChild lbl
    box.appendChild subbox

    return box

  _createCustomRuleWidget: (doc, description) ->
    {
      ruleset
      origin
      destination
    } = description

    customRuleBox = createElement doc, 'hbox',
      class: 'policeman-popup-custom-rule-box'

    customRuleBox.appendChild createElement doc, 'label',
      value: l10n 'popup_custom_rule.0'
      class: 'policeman-popup-label-aligned-like-button'

    allow = ['allow', l10n 'popup_custom_rule.allow']
    reject = ['reject', l10n 'popup_custom_rule.reject']
    customRuleBox.appendChild allowRejectBtn = DataRotationButton::create doc,
      valuesLabels: if manager.enabled('reject_any') \
          then [allow, reject] \ # whitelist mode
          else [reject, allow]   # blacklist mode
      style: 'background: ' + if manager.enabled('reject_any') \
          then positiveBackgroundColor.toCssString()
          else negativeBackgroundColor.toCssString()
      click: ->
        if 'reject' == Button::getData @
          @style.background = negativeBackgroundColor.toCssString()
        else
          @style.background = positiveBackgroundColor.toCssString()

    customRuleBox.appendChild createElement doc, 'label',
      value: l10n 'popup_custom_rule.1'
      class: 'policeman-popup-label-aligned-like-button'

    customRuleBox.appendChild typeBtn = DataRotationButton::create doc,
      valuesLabels: ([t, l10n('popup_custom_rule.2') + ' ' + localizeType(t)] \
              for t in [WILDCARD_TYPE].concat(SUPPORTED_TYPES))

    customRuleBox.appendChild createElement doc, 'label',
      value: l10n 'popup_custom_rule.3'
      class: 'policeman-popup-label-aligned-like-button'

    customRuleBox.appendChild originBtn = DataRotationButton::create doc,
      valuesLabels: ([d, d or l10n 'popup_rule_any_domain'] \
                        for d in superdomains(origin, 2).concat(''))
      tooltiptext: l10n 'popup_domain_rotation_button.tip'

    customRuleBox.appendChild createElement doc, 'label',
      value: l10n 'popup_custom_rule.4'
      class: 'policeman-popup-label-aligned-like-button'

    customRuleBox.appendChild destinationBtn = DataRotationButton::create doc,
      valuesLabels: ([d, d or l10n 'popup_rule_any_domain'] \
                        for d in superdomains(destination, 2).concat(''))
      tooltiptext: l10n 'popup_domain_rotation_button.tip'

    customRuleBox.appendChild createElement doc, 'label',
      value: l10n 'popup_custom_rule.5'
      class: 'policeman-popup-label-aligned-like-button'

    customRuleBox.appendChild createElement doc, 'spacer',
      flex: 1
      orient: 'vertical'

    customRuleBox.appendChild Button::create doc,
      label: l10n 'popup_add_rule'
      click: =>
        popup.autoreload.require(doc)
        allowReject = DataRotationButton::getData allowRejectBtn
        origin_ = DataRotationButton::getData originBtn
        destination_ = DataRotationButton::getData destinationBtn
        type_ = DataRotationButton::getData typeBtn
        ruleset[allowReject] origin_, destination_, type_
        @update doc

    return customRuleBox

  _createRuleWidget: (doc, description) ->
    {
      ruleset: rs
      origin: o
      destination: d
      type: t
      decision
    } = description
    hbox = createElement doc, 'hbox'

    hbox.appendChild @_createBasicRuleWidget doc,
      origin: o
      destination: d
      type: t
      decision: decision

    hbox.appendChild createElement doc, 'spacer',
      flex: 1
      orient: 'vertical'

    # "Move to another ruleset" button
    if @_rulesetId == 'user_persistent'
      anotherRs = manager.get 'user_temporary'
      anotherWidget = temporaryRulesetEdit
      label = l10n 'popup_persistent_rule_to_temporary'
    else
      anotherRs = manager.get 'user_persistent'
      anotherWidget = persistentRulesetEdit
      label = l10n 'popup_temporary_rule_to_persistent'
    if anotherRs
      hbox.appendChild Button::create doc,
        label: label
        click: =>
          popup.autoreload.require(doc)
          rs.revoke o, d, t
          anotherRs[if decision then 'allow' else 'reject'] o, d, t
          @update doc
          anotherWidget.update doc

    # "Remove" button
    hbox.appendChild Button::create doc,
      label: l10n 'popup_delete_rule'
      click: =>
        popup.autoreload.require(doc)
        rs.revoke o, d, t
        @update doc
    return hbox

  populate: (doc) ->
    rs = manager.get @_rulesetId
    return if not rs

    selectedOrigin = originSelection.selectedData
    selectedDestination = destinationSelection.selectedData

    fragment = doc.createDocumentFragment()

    rules = createElement doc, 'vbox',
      class: 'policeman-existing-rules'

    supportedTypes = SUPPORTED_TYPES.concat [WILDCARD_TYPE]

    if selectedOrigin and selectedDestination
      # show rules that apply to selected origin and destination only
      rs.superdomainsCheckOrder selectedOrigin, selectedDestination, (o, d) =>
        for t in supportedTypes
          decision = rs.lookup o, d, t
          if decision isnt null
            rules.appendChild @_createRuleWidget doc,
              ruleset: rs
              origin: o
              destination: d
              type: t
              decision: decision
        return
    else
      # show rules that influenced anything in the current tab
      # filtered by selected origin or destination if any
      # ordered by priority
      rulesSet = Object.create null # origin -> dest -> type -> index
      rulesList = [] # [[o, d, t, decision]]
      index = 0
      for [o, d, c, decision] in memo.getByTab tabs.getCurrent()
        continue unless (o.schemeType == d.schemeType == 'web')
        continue if selectedOrigin and not (isSuperdomain selectedOrigin, o.host)
        continue if selectedDestination and not (isSuperdomain selectedDestination, d.host)
        rs.superdomainsCheckOrder o.host, d.host, (o, d) =>
          for t in supportedTypes
            decision = rs.lookup o, d, t
            continue if decision is null
            defaults rulesSet, o, Object.create null
            defaults rulesSet[o], d, Object.create null
            if t of rulesSet[o][d]
              delete rulesList[rulesSet[o][d][t]]
              rulesList[index] = [o, d, t, decision]
            else
              rulesList[index] = [o, d, t, decision]
            rulesSet[o][d][t] = index
            index += 1
          return
      for x in rulesList
        continue unless x
        [origin, destination, type, decision] = x
        rules.appendChild @_createRuleWidget doc, {
          ruleset: rs
          origin
          destination
          type
          decision
        }

    fragment.appendChild rules

    fragment.appendChild createElement doc, 'separator',
      class: 'thin'

    fragment.appendChild @_createCustomRuleWidget doc,
      ruleset: rs
      origin: selectedOrigin
      destination: selectedDestination

    doc.getElementById(@_containerId).appendChild fragment


temporaryRulesetEdit = new (class extends RulesetEditButtons
  populate: (doc) ->
    super doc

    rs = manager.get @_rulesetId
    doc.getElementById('policeman-popup-temporary-ruleset-container') \
            .hidden = not rs
    return if not rs

    container = doc.getElementById('policeman-popup-temporary-ruleset-purge-container')
    if not rs.isEmpty()
      container.appendChild Button::create doc,
        label: l10n 'popup_revoke_all_temporary'
        click: =>
          popup.autoreload.require(doc)
          rs.revokeAll()
          @update doc

  purge: (doc) ->
    super doc

    container = doc.getElementById('policeman-popup-temporary-ruleset-purge-container')
    removeChildren container

) 'policeman-popup-temporary-edit-container', 'user_temporary'

persistentRulesetEdit = new (class extends RulesetEditButtons
  populate: (doc) ->
    super doc
    doc.getElementById('policeman-popup-persistent-ruleset-container') \
            .hidden = not manager.enabled @_rulesetId
) 'policeman-popup-persistent-edit-container', 'user_persistent'


footerCheckButtons = new (class extends ContainerPopulation
  populate: (doc) ->
    fragment = doc.createDocumentFragment()

    fragment.appendChild CheckButton::create doc,
      id: 'policeman-popup-reload-button'
      label: l10n 'popup_reload_page'
      checked: popup.autoreload.enabled()
      click: ->
        if CheckButton::checked @
          popup.autoreload.enable()
        else
          popup.autoreload.disable()

    fragment.appendChild CheckButton::create doc,
      label: l10n 'popup_suspend_operation'
      checked: manager.suspended()
      click: ->
        if CheckButton::checked @
          manager.suspend()
        else
          manager.unsuspend()

    doc.getElementById(@_containerId).appendChild fragment

) 'policeman-popup-footer-left'


footerLinkButtons = new (class extends ContainerPopulation
  populate: (doc) ->
    fragment = doc.createDocumentFragment()

    fragment.appendChild LinkButton::create doc,
      label: l10n 'popup_open_help'
      reuse: true
      url: 'https://github.com/futpib/policeman/wiki/Help'

    fragment.appendChild LinkButton::create doc,
      label: l10n 'popup_open_preferences'
      reuse: true
      url: 'chrome://policeman/content/preferences.xul#user-rulesets'

    doc.getElementById(@_containerId).appendChild fragment

) 'policeman-popup-footer-right'


statusIndicator =
  id: 'policeman-popup-status-indicator-container'
  nothingToShowId: 'policeman-popup-no-web-requests-container'
  progressIndicatorId: 'policeman-popup-progress-indicator-container'

  updateStarted: (doc) ->
    doc.getElementById(@id).hidden = false
    doc.getElementById(@nothingToShowId).hidden = true
    doc.getElementById(@progressIndicatorId).hidden = false

  updateFinished: (doc) ->
    webRequests = memo.getByTab(tabs.getCurrent()).filter ([o,d,c]) ->
      (o.schemeType == d.schemeType == 'web')
    noWebRequestsRecorded = not webRequests.length
    doc.getElementById(@id).hidden = not noWebRequestsRecorded
    doc.getElementById(@nothingToShowId).hidden = not noWebRequestsRecorded
    doc.getElementById(@progressIndicatorId).hidden = noWebRequestsRecorded


prefs.define AUTORELOAD_PREF = 'ui.popup.autoReloadPageOnHiding',
  default: false

exports.popup = popup =
  id: 'policeman-popup'

  styleURI: Services.io.newURI 'chrome://policeman/skin/popup.css', null, null

  init: ->
    @addUI(w) for w in windows.list
    windows.onOpen.add @addUI.bind @
    windows.onClose.add @removeUI.bind @
    onShutdown.add => @removeUI(w) for w in windows.list

    tabs.onSelect.add (t) =>
      if @_visible
        @cleanupUI t.ownerDocument
        @updateUI t.ownerDocument

    originSelection.onSelection.add (btn) ->
      destinationSelection.update btn.ownerDocument
    destinationSelection.onSelection.add (btn) ->
      rejectedFilter.update btn.ownerDocument
      allowedFilter.update btn.ownerDocument
      temporaryRulesetEdit.update btn.ownerDocument
      persistentRulesetEdit.update btn.ownerDocument
    rejectedFilter.onSelection.add (btn) ->
      rejectedList.update btn.ownerDocument
    allowedFilter.onSelection.add (btn) ->
      allowedList.update btn.ownerDocument

  onToobarbuttonCommand: (e) ->
    btn = e.target
    doc = btn.ownerDocument
    @open doc, btn

  open: (doc, anchor=null) ->
    panel = doc.getElementById @id
    panel.openPopup anchor, 'bottomcenter topright', 0, 0, no, no

  hide: (doc) ->
    panel = doc.getElementById @id
    panel.hidePopup()

  onShowing: (e) ->
    doc = e.target.ownerDocument
    @autoreload.onShowing doc
    @updateUI doc
    @_visible = true

  onHiding: (e) ->
    doc = e.target.ownerDocument
    @cleanupUI doc
    if @autoreload.enabled() and @autoreload.required()
      tabs.reload tabs.getCurrent()
    @_visible = false

  addUI: (win) ->
    doc = win.document
    overlayQueue.add doc, 'chrome://policeman/content/popup.xul', =>
      panel = doc.getElementById @id
      panel.addEventListener 'popupshown', @onShowing.bind @
      panel.addEventListener 'popuphidden', @onHiding.bind @

    loadSheet doc.defaultView, @styleURI

  removeUI: (win) ->
    doc = win.document
    removeNode doc.getElementById @id
    removeSheet doc.defaultView, @styleURI

  updateUI: (doc) ->
    originSelection.update doc
    footerCheckButtons.update doc
    footerLinkButtons.update doc

    statusIndicator.updateFinished doc

  cleanupUI: (doc) ->
    destinationSelection.purge doc
    rejectedFilter.purge doc
    allowedFilter.purge doc
    temporaryRulesetEdit.purge doc
    persistentRulesetEdit.purge doc
    rejectedList.purge doc
    allowedList.purge doc

    statusIndicator.updateStarted doc

  autoreload:
    _reloadRequired: false
    enabled: -> prefs.get AUTORELOAD_PREF
    enable: -> prefs.set AUTORELOAD_PREF, true
    disable: -> prefs.set AUTORELOAD_PREF, false
    required: -> @_reloadRequired
    require: (doc) ->
      @_reloadRequired = true
    onShowing: (doc) ->
      @_reloadRequired = false


do popup.init
