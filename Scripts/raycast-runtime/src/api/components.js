// The @raycast/api components: each renders one host node, element-valued props move into `__slot`s.

import {
  createContext,
  createElement as h,
  useCallback,
  useContext,
  useEffect,
  useImperativeHandle,
  useMemo,
  useRef,
  useState,
} from "react";
import { SLOT_TYPE } from "../reconciler.js";
import { Icon, ActionStyle } from "./enums.generated.js";

/// `single: true` marks a slot whose parent expects one node rather than a list.
function slot(name, element, single = true) {
  if (element === undefined || element === null || element === false) return null;
  return h(SLOT_TYPE, { key: `__slot_${name}`, name, single }, element);
}

function omit(props, keys) {
  const out = {};
  for (const key of Object.keys(props)) if (!keys.includes(key)) out[key] = props[key];
  return out;
}

// ─── Navigation ─────────────────────────────────────────────────────

const NavigationContext = createContext(null);

export function useNavigation() {
  const navigation = useContext(NavigationContext);
  if (navigation) return navigation;
  // A no-view command has no stack; make push/pop inert rather than a crash.
  return { push: () => {}, pop: () => {} };
}

export const Navigation = { useNavigation };

/// Keeps every pushed screen mounted so popping restores state; `controls` lets Escape pop directly.
export function NavigationRoot({ initial, onStackChange, controls }) {
  const [stack, setStack] = useState(() => [{ key: 0, element: initial }]);
  const nextKey = useRef(1);

  const push = useCallback(
    (element) => {
      setStack((current) => {
        const next = [...current, { key: nextKey.current++, element }];
        onStackChange?.(next.length);
        return next;
      });
    },
    [onStackChange],
  );

  const pop = useCallback(() => {
    setStack((current) => {
      if (current.length <= 1) return current;
      const next = current.slice(0, -1);
      onStackChange?.(next.length);
      return next;
    });
  }, [onStackChange]);

  const value = useMemo(() => ({ push, pop }), [push, pop]);
  if (controls) {
    controls.push = push;
    controls.pop = pop;
  }

  return h(
    NavigationContext.Provider,
    { value },
    stack.map((entry, index) =>
      h("__screen", { key: entry.key, active: index === stack.length - 1 }, entry.element),
    ),
  );
}

// ─── Form state ─────────────────────────────────────────────────────

const FormContext = createContext(null);

function useFormRegistration(id, value, setValue) {
  const form = useContext(FormContext);
  if (form && id) form.fields.set(id, { value, setValue });
  return form;
}

/// A field's local value, or the controlled `value` prop when the extension supplies one.
function useFieldValue(props, fallback) {
  const [local, setLocal] = useState(() => (props.value !== undefined ? props.value : props.defaultValue ?? fallback));
  const controlled = props.value !== undefined;
  const value = controlled ? props.value : local;
  const setValue = useCallback(
    (next) => {
      if (!controlled) setLocal(next);
    },
    [controlled],
  );
  useFormRegistration(props.id, value, setLocal);
  return [value, setValue];
}

/// No `forwardRef` (React 19 passes `ref` as a prop), so components stay callable as plain functions.
function useFieldRef(ref, { setValue, initial, id }) {
  useImperativeHandle(ref ?? null, () => ({
    focus: () => hostFieldCommand("focus", id),
    reset: () => setValue(initial),
  }));
}

let hostFieldCommand = () => {};
export function setFieldCommandHandler(handler) {
  hostFieldCommand = handler;
}

// ─── List ───────────────────────────────────────────────────────────

/// `throttle` waits for typing to pause, so a slow reply for an older query can't land last.
function useThrottledSearch(props) {
  const latest = useRef();
  const timer = useRef();
  latest.current = props.onSearchTextChange;
  useEffect(() => () => clearTimeout(timer.current), []);
  const delayed = useCallback((text) => {
    clearTimeout(timer.current);
    timer.current = setTimeout(() => latest.current?.(text), 300);
  }, []);
  return props.throttle && props.onSearchTextChange ? delayed : props.onSearchTextChange;
}

function makeSearchable(type) {
  return function Searchable(props) {
    const rest = omit(props, ["children", "actions", "searchBarAccessory"]);
    rest.onSearchTextChange = useThrottledSearch(props);
    // Raycast filters client-side unless the extension takes over the search text.
    if (rest.filtering === undefined) rest.filtering = props.onSearchTextChange === undefined;
    return h(type, rest, slot("actions", props.actions), slot("searchBarAccessory", props.searchBarAccessory), props.children);
  };
}

const List = makeSearchable("List");

function ListItem(props) {
  return h(
    "List.Item",
    omit(props, ["children", "actions", "detail"]),
    slot("actions", props.actions),
    slot("detail", props.detail),
    props.children,
  );
}

function ListItemDetail(props) {
  return h("List.Item.Detail", omit(props, ["children", "metadata"]), slot("metadata", props.metadata), props.children);
}

function Section(type) {
  return function SectionComponent(props) {
    return h(type, omit(props, ["children"]), props.children);
  };
}

function EmptyView(type) {
  return function EmptyViewComponent(props) {
    return h(type, omit(props, ["children", "actions"]), slot("actions", props.actions), props.children);
  };
}

/// Hook-free, so callable without JSX: Swift owns the selection and reports it through `onChange`.
function makeSearchDropdown(type) {
  function Dropdown(props) {
    return h(type, omit(props, ["children"]), props.children);
  }
  Dropdown.Item = Section(`${type}.Item`);
  Dropdown.Section = Section(`${type}.Section`);
  return Dropdown;
}

List.Item = ListItem;
List.Item.Detail = ListItemDetail;
List.Section = Section("List.Section");
List.EmptyView = EmptyView("List.EmptyView");
List.Dropdown = makeSearchDropdown("List.Dropdown");

// ─── Grid ───────────────────────────────────────────────────────────

const Grid = makeSearchable("Grid");

function GridItem(props) {
  return h("Grid.Item", omit(props, ["children", "actions"]), slot("actions", props.actions), props.children);
}

Grid.Item = GridItem;
Grid.Section = Section("Grid.Section");
Grid.EmptyView = EmptyView("Grid.EmptyView");
Grid.Dropdown = makeSearchDropdown("Grid.Dropdown");

// ─── Detail ─────────────────────────────────────────────────────────

function Detail(props) {
  return h(
    "Detail",
    omit(props, ["children", "actions", "metadata"]),
    slot("actions", props.actions),
    slot("metadata", props.metadata),
    props.children,
  );
}

function DetailMetadata(props) {
  return h("Detail.Metadata", omit(props, ["children"]), props.children);
}
DetailMetadata.Label = Section("Detail.Metadata.Label");
DetailMetadata.Link = Section("Detail.Metadata.Link");
DetailMetadata.Separator = Section("Detail.Metadata.Separator");
DetailMetadata.TagList = Section("Detail.Metadata.TagList");
DetailMetadata.TagList.Item = Section("Detail.Metadata.TagList.Item");

Detail.Metadata = DetailMetadata;
// List.Item.Detail shares Detail's metadata components.
ListItemDetail.Metadata = DetailMetadata;

// ─── Form ───────────────────────────────────────────────────────────

function Form(props) {
  const fields = useRef(new Map()).current;
  const context = useMemo(() => ({ fields, values: () => collectValues(fields) }), [fields]);
  return h(
    FormContext.Provider,
    { value: context },
    h(
      "Form",
      omit(props, ["children", "actions", "searchBarAccessory"]),
      slot("actions", props.actions),
      slot("searchBarAccessory", props.searchBarAccessory),
      props.children,
    ),
  );
}

function collectValues(fields) {
  const values = {};
  for (const [id, field] of fields) values[id] = field.value;
  return values;
}

function makeField(type, fallback) {
  return function Field(props) {
    const [value, setValue] = useFieldValue(props, fallback);
    useFieldRef(props.ref, { setValue, initial: props.defaultValue ?? fallback, id: props.id });
    const rest = omit(props, ["children", "ref", "value", "defaultValue", "onChange", "onBlur", "onFocus"]);
    return h(
      type,
      {
        ...rest,
        value,
        onTinycastChange: (next) => {
          const decoded = type === "Form.DatePicker" ? decodeDate(next) : next;
          setValue(decoded);
          props.onChange?.(decoded);
        },
        onTinycastBlur: props.onBlur ? () => props.onBlur({ target: { value } }) : undefined,
        onTinycastFocus: props.onFocus ? () => props.onFocus({ target: { value } }) : undefined,
      },
      props.children,
    );
  };
}

function decodeDate(value) {
  if (value === null || value === undefined || value === "") return null;
  if (value instanceof Date) return value;
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

Form.TextField = makeField("Form.TextField", "");
Form.PasswordField = makeField("Form.PasswordField", "");
Form.TextArea = makeField("Form.TextArea", "");
Form.Checkbox = makeField("Form.Checkbox", false);
Form.DatePicker = makeField("Form.DatePicker", null);
Form.DatePicker.Type = undefined; // filled in from the generated enums by index.js
Form.TagPicker = makeField("Form.TagPicker", []);
Form.TagPicker.Item = Section("Form.TagPicker.Item");
Form.FilePicker = makeField("Form.FilePicker", []);
Form.Separator = Section("Form.Separator");
Form.Description = Section("Form.Description");
Form.LinkAccessory = Section("Form.LinkAccessory");
// A form dropdown is a value-carrying field, unlike the search-bar dropdowns above.
Form.Dropdown = makeField("Form.Dropdown", "");
Form.Dropdown.Item = Section("Form.Dropdown.Item");
Form.Dropdown.Section = Section("Form.Dropdown.Section");
// The deprecated flat aliases (`Form.DropdownItem`, …) still appear in shipped bundles.
Form.DropdownItem = Form.Dropdown.Item;
Form.DropdownSection = Form.Dropdown.Section;
Form.TagPickerItem = Form.TagPicker.Item;

// ─── ActionPanel / Action ───────────────────────────────────────────

function ActionPanel(props) {
  return h("ActionPanel", omit(props, ["children"]), props.children);
}
ActionPanel.Section = Section("ActionPanel.Section");
// Deprecated alias kept because installed extensions still ship it.
ActionPanel.Item = Action;
ActionPanel.Submenu = function Submenu(props) {
  return h("ActionPanel.Submenu", omit(props, ["children"]), props.children);
};

/// Every convenience action funnels into this one host node, so Swift only ever renders "Action".
function Action(props) {
  return h("Action", omit(props, ["children"]));
}

/// Injected by api/index.js, which would otherwise be a circular import of the system APIs.
let effects = {};
export function setActionEffects(next) {
  effects = next;
}

const CONVENIENCE_KEYS = ["shortcut", "style", "autoFocus"];

/// One "Action" node forwarding `title`, `icon` and `keys`, each falling back to its `defaults` entry.
function convenience(displayName, defaults, onAction, keys = CONVENIENCE_KEYS) {
  const Component = function ConvenienceAction(props) {
    const forwarded = {};
    for (const key of ["title", "icon", ...keys]) forwarded[key] = key in defaults ? props[key] ?? defaults[key] : props[key];
    return h(Action, { ...forwarded, onAction: () => onAction(props) });
  };
  Component.displayName = displayName;
  return Component;
}

const SHORTCUT_ONLY = ["shortcut"];

Action.CopyToClipboard = convenience("Action.CopyToClipboard", { title: "Copy to Clipboard", icon: Icon.CopyClipboard }, async (props) => {
  await effects.copy({ content: props.content, concealed: props.concealed });
  props.onCopy?.(props.content);
});

Action.Paste = convenience("Action.Paste", { title: "Paste in Active App", icon: Icon.Clipboard }, async (props) => {
  await effects.paste({ content: props.content });
  props.onPaste?.(props.content);
});

Action.OpenInBrowser = convenience("Action.OpenInBrowser", { title: "Open in Browser", icon: Icon.Globe }, async (props) => {
  await effects.open({ target: props.url, application: props.application });
  props.onOpen?.(props.url);
});

Action.Open = convenience("Action.Open", { icon: Icon.Document }, async (props) => {
  await effects.open({ target: props.target, application: props.application });
  props.onOpen?.(props.target);
});

Action.OpenWith = convenience("Action.OpenWith", { title: "Open With", icon: Icon.AppWindow }, async (props) => {
  await effects.openWith({ path: props.path });
  props.onOpen?.(props.path);
}, SHORTCUT_ONLY);

Action.ShowInFinder = convenience("Action.ShowInFinder", { title: "Show in Finder", icon: Icon.Finder }, async (props) => {
  await effects.showInFinder({ path: props.path });
  props.onShow?.(props.path);
}, SHORTCUT_ONLY);

const TRASH_DEFAULTS = { title: "Move to Trash", icon: Icon.Trash, style: ActionStyle.Destructive };
Action.Trash = convenience("Action.Trash", TRASH_DEFAULTS, async (props) => {
  await effects.trash({ paths: props.paths });
  props.onTrash?.(props.paths);
}, ["style", "shortcut"]);

Action.Push = function ActionPush(props) {
  const { push } = useNavigation();
  return h(Action, {
    title: props.title,
    icon: props.icon,
    shortcut: props.shortcut,
    style: props.style,
    autoFocus: props.autoFocus,
    onAction: () => {
      push(props.target);
      props.onPush?.();
    },
  });
};

Action.SubmitForm = function ActionSubmitForm(props) {
  const form = useContext(FormContext);
  return h(Action, {
    title: props.title ?? "Submit Form",
    icon: props.icon,
    shortcut: props.shortcut,
    style: props.style,
    autoFocus: props.autoFocus,
    onAction: () => props.onSubmit?.(form ? form.values() : {}),
  });
};

Action.CreateSnippet = convenience("Action.CreateSnippet", { title: "Create Snippet", icon: Icon.Snippets }, (props) => effects.createSnippet(props.snippet), SHORTCUT_ONLY);
Action.CreateQuicklink = convenience("Action.CreateQuicklink", { title: "Create Quicklink", icon: Icon.Link }, (props) => effects.createQuicklink(props.quicklink), SHORTCUT_ONLY);
Action.ToggleQuickLook = convenience("Action.ToggleQuickLook", { title: "Quick Look", icon: Icon.Eye }, (props) => effects.quickLook(props.target), SHORTCUT_ONLY);

Action.PickDate = function ActionPickDate(props) {
  return h(Action, {
    title: props.title,
    icon: props.icon ?? Icon.Calendar,
    shortcut: props.shortcut,
    style: props.style,
    // Rendered as a submenu-less action; Swift opens its own date picker and answers through onChange.
    pickDate: { type: props.type, min: props.min, max: props.max },
    onTinycastChange: (value) => props.onChange?.(decodeDate(value)),
  });
};

Action.InstallMCPServer = convenience("Action.InstallMCPServer", { title: "Install MCP Server", icon: Icon.Plug }, () => effects.unsupported("Action.InstallMCPServer"), SHORTCUT_ONLY);

// ─── Menu bar ───────────────────────────────────────────────────────

function MenuBarExtra(props) {
  return h("MenuBarExtra", omit(props, ["children"]), props.children);
}
MenuBarExtra.Item = (props) =>
  h("MenuBarExtra.Item", omit(props, ["children", "alternate"]), slot("alternate", props.alternate));
MenuBarExtra.Submenu = Section("MenuBarExtra.Submenu");
MenuBarExtra.Section = Section("MenuBarExtra.Section");
MenuBarExtra.Separator = Section("MenuBarExtra.Separator");

export { List, Grid, Detail, Form, ActionPanel, Action, MenuBarExtra, FormContext };
