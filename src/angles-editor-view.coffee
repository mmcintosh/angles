#
# Events managed in the ACEEditorView.dispather:
#
#   editor:change - an editor change event
#   editor:reload - force the editor to reload content from the model
#   editor:error  - an error reported by the editor or wrapper
#
#   document:switch  - a request to change the document the editor is editing
#   document:save    - a request to save the document currently in the editor
#
#   validation:start - notice that validation is beginning
#   validation:end   - notice that validation has finished
#   validation:error - the report of a validation error
#
# If you replace the Angles.ACEEditorView with a different view to wrap
# a different editor, you will need to implement a getDocument() function
# that returns the same properties as the one here, but with data from
# your editor instance. This lets the validator not depend on the ACE
# API.
#
# To provide different storage for the collection, replace 
# Angles.XMLDocumentList (here, we're using local storage):
#
#  Angles.XMLDocumentList = Backbone.Collection.extend({
#    mode: Angles.XMLDocument,
#    localStorage: new Backbone.LocalStorage("SomeCollection")
#  });
#

window.Angles = {}
((Angles,_,Backbone,ace) ->
  ACEEditor = null

  # XMLDocument
  class Angles.XMLDocument extends Backbone.Model
    defaults:
      "name"   : "untitled"
      "content": ""

    validate: (attrs) ->
      # console.log(attrs);
      #if(attrs.name === undefined) {
      #  return "document must have a name";
      #}
      #if(attrs.name =~ /^\s*$/) {
      #  return "document must have a name";
      #}

  # XMLDocument List
  class Angles.XMLDocumentList extends Backbone.Collection
    model: Angles.XMLDocument

  # Notification
  class Angles.Notification extends Backbone.Model
    defaults:
      "type"    : ""
      "info"    : ""
      "message" : ""
      "resource": ""
      "location": 
        "column": -1
        "row"   : -1

  # Notification List
  class Angles.NotificationList extends Backbone.Collection
    model: Angles.Notification

  #
  # This file selector will list the documents in the Angles.XMLDocumentList
  # collection and allow selection of a document.
  #
  # Fires a document:change event when the selected file is to be loaded
  # into the editor. The event's data parameter is the model object from
  # which to get the content.
  #
  # options:
  #
  # * el: element into which this view should be rendered
  # * dispatcher: dispatcher object to use for events
  # * collection: collection of models from which a model should be selected
  #
  # template classes:
  #   .file-list - list of files - new files are appended to the end
  #   .new-file  - element that triggers a new file dialog
  #
  #
  # _.templateSettings =
  #   interpolate: /\{\{(.+?)\}\}/g
  #   escape: /\{\{-(.+?)\}\}/g

  class Angles.FileSelector extends Backbone.View

    initialize: ->
      @template = _.template $('#file-list-template').html()

    render: ->
      @$el.html @template {}
      @collection.each @addOne, @
      @

    addOne: (model) ->
      view = new Angles.FileSelectorRow
        model: model
      @$("form").append view.render().$el

  class Angles.FileSelectorRow extends Backbone.View

    initialize: ->
      @template = _.template $('#file-item-template').html()
      @listenTo @model, 'change', @render
      @listenTo @model, 'destroy', @remove

    render: ->
      @$el.html @template @model.toJSON()
      @

  class Angles.NotificationTable extends Backbone.View

    initialize: ->
      @template = _.template $('#notification-list-template').html()

    render: ->
      @$el.html @template {}
      @listenTo @collection, 'add', @addOne
      @

    addOne: (model) ->
      view = new Angles.NotificationRow
        model: model
      @$(".notifications").append view.render().$el

  class Angles.NotificationRow extends Backbone.View

    initialize: ->
      @template = _.template $('#notification-template').html()
      @listenTo @model, 'change', @render
      @listenTo @model, 'destroy', @remove

    render: ->
      @$el.html @template @model.toJSON()
      @

  #
  # We intend ACEEditorView to be a singleton class for a particular area
  # on the page - not to be instantiated for each document in the collection.
  #
  # You may pass a dispatcher object into the initializer if you want to
  # use one from another application to allow integration.
  #

  class Angles.ACEEditorView extends Backbone.View
    tagName: "div"
    className: "ace-editor"

    initialize: ->
      annotations = []
      dispatcher = @options.dispatcher or _.clone Backbone.Events
      @dispatcher = dispatcher

      dispatcher.on "editor:reload", =>
        @clearAnnotations()
        @setContent()

      dispatcher.on "document:save", => @saveModel()

      dispatcher.on "validation:start", =>
        annotations = [];
        @dispatcher.trigger 'notification:clear'

      dispatcher.on "validation:error", (e) =>
        annotations.push(e)
        n =
          type: "validation"
          info: e.type
          message: e.text
          location:
            row: e.row
            column: e.column
        @dispatcher.trigger 'notification:push', n
      
      dispatcher.on "validation:end", =>
        select = @$editor.getSelection()

        @clearAnnotations()
        @$editor.focus()
        if annotations.length > 0
          @$editor.gotoLine annotations[0].row+1, annotations[0].column, true
          select.selectWordLeft()
          select.selectWordLeft()

        @$editor.session.setAnnotations(annotations)

      dispatcher.on "document:switch", (e) => @setModel(e)

    render: ->
      @$editor = ace.edit(@el);
      @$editor.getSession().on 'change', (e) => @dispatcher.trigger 'editor:change', e
      @$editor.getSession().setMode "ace/mode/xml"

      # Load ace modules #

      #ace.config.set("basePath", "../deps/")      
      ace.config.loadModule 'ext/angles', =>

        @$editor.setOptions
          enableODDAutocompletion: true

        completer = 
          getCompletions: (editor, session, pos, prefix, callback) =>   
            if @$context?
              context = this.$context

              _findParent = (row, column) ->
                openTags = []
                closedTags = []
                allTags = []
                isOpeningTag = false
                isClosingTag = false

                finalTag = ''
                maxRow = editor.getSession().getLength()

                _scanRow = (row, column) ->
                  return if row > maxRow
                  curColumn = 0
                  tokens = editor.getSession().getTokens(row)
                  lastTag = null
                  for token in tokens
                    curColumn += token.value.length

                    isfinal = ->
                      switch
                        when openTags.length == 0
                          true
                        when openTags.length == closedTags.length
                          openTags.pop()
                          closedTags.pop()
                          false
                        when openTags[openTags.length-1] == closedTags[closedTags.length-1]
                          openTags.pop()
                          closedTags.pop()
                          false
                        else
                          false

                    latestTag = token.value if token.type == "meta.tag.tag-name"

                    if curColumn > column
                      switch
                        when token.type == "meta.tag" and token.value == "<"
                          isOpeningTag = true
                        when token.type == "meta.tag.r" and token.value == ">" and (isOpeningTag or isClosingTag)
                          isOpeningTag = false
                          isClosingTag = false
                        when token.type == "meta.tag.r" and token.value == ">" and openTags.length == 0
                          # The cursor must be on a closing tag, 
                          # return element value
                          return latestTag
                        when token.type == "meta.tag" and token.value == "</"
                          isClosingTag = true
                        when token.type == "meta.tag.r" and token.value == "/>"
                          isOpeningTag = false
                          isClosingTag = false
                          milestone = openTags[openTags.length-1]
                          milestone = latestTag if !milestone?
                          closedTags.push milestone
                          return milestone if isfinal()
                        when token.type == "meta.tag.tag-name" and isOpeningTag
                          allTags.push "<#{token.value}>"
                          openTags.push token.value
                          return token.value if isfinal()
                        when token.type == "meta.tag.tag-name" and isClosingTag
                          allTags.push "</#{token.value}>"
                          closedTags.push token.value
                          return token.value if isfinal()

                  _scanRow(row+1, 0)

                _scanRow(row, column)

              pos = editor.getCursorPosition()              
              ident = _findParent(pos.row, pos.column)
              completions = []

              children = context.getChildrenOf(ident);

              if children?
                for c in children
                  completions.push
                    caption: c.ident,
                    snippet: "#{c.ident}></#{c.ident}>",
                    meta: "element"
              else
                completions.push
                  caption: "unknown parent"
                  snippet: ""
                  meta: "element"

              if completions.length > 0 
                callback null, completions
            else
              0 #console.log 'Context Help component not loaded'  
        @$editor.completers = [completer]

        ace.config.on "desc", (e) =>
          @dispatcher.trigger("editor:context", e.ident)

        ace.config.on "desc:clear", (e) =>
          @dispatcher.trigger 'notification:clear'

      @

    setContent: -> @$editor.setValue @model.get('content')


    getContent: -> @$editor.getValue()

    getDocument: ->
      getValue: => @$editor.getValue()
      getLength: => @$editor.session.getDocument().getLength()
      getLine: (n) => @$editor.session.getDocument().getLine(n)

    saveModel: ->
      @model.set 'content', @getContent()
      @model.save
        success: => @dispatcher.trigger "editor:reload"
        error: => @dispatcher.trigger "editor:error", "Unable to change document"

    setModel: (m) ->
      @model = m;
      @dispatcher.trigger "editor:reload"

    clearAnnotations: -> @$editor.session.clearAnnotations()

    setMode: (m) -> @$editor.getSession().setMode(m)

)(window.Angles,_,Backbone,ace)
