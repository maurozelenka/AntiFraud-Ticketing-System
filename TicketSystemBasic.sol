// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TicketSystemBasic
 * @author Diego (MUniCS - Tecnologías de Registro Distribuido y Blockchain)
 * @notice Versión Básica: Sistema de emisión, venta y reventa controlada de entradas
 *         para eventos con límite máximo de precio de reventa y validación en acceso.
 * @dev Implementa optimización de gas mediante Custom Errors, Struct Packing e Immutable variables.
 */
contract TicketSystemBasic {

    // =========================================================================
    // CUSTOM ERRORS (Optimización de Gas)
    // =========================================================================
    error OnlyOrganizerAllowed();
    error OnlyTicketOwnerAllowed();
    error SoldOut();
    error IncorrectPayment(uint256 expected, uint256 provided);
    error TicketDoesNotExist(uint256 ticketId);
    error TicketNotForSale(uint256 ticketId);
    error TicketAlreadyUsed(uint256 ticketId);
    error CannotBuyOwnTicket();
    error PriceExceedsMaxLimit(uint256 proposedPrice, uint256 maxAllowed);
    error InvalidPrice();
    error TransferFailed();
    error NoFundsToWithdraw();

    // =========================================================================
    // ESTRUCTURA DE DATOS (Struct Packing: 22 bytes en el primer slot)
    // =========================================================================
    struct Ticket {
        address owner;       // 20 bytes
        bool isUsed;         // 1 byte
        bool isForSale;      // 1 byte
        // Total en Slot 1: 22 bytes <= 32 bytes (Ahorro de un SSTORE)
        uint256 resalePrice; // 32 bytes en Slot 2
    }

    // =========================================================================
    // VARIABLES DE ESTADO
    // =========================================================================
    address public immutable organizer;              // Dirección del organizador (no gasta SLOAD)
    uint256 public immutable ticketPrice;            // Precio original en Wei
    uint256 public immutable maxMarkupPercentage;    // Porcentaje máx. sobreprecio reventa (ej. 10 = +10%)
    uint256 public immutable maxResalePrice;         // Precio tope calculado en el despliegue
    uint256 public immutable totalTickets;           // Aforo total

    uint256 public ticketsSold;                      // Contador de entradas vendidas
    mapping(uint256 => Ticket) public tickets;       // ticketId => Ficha de la entrada

    // =========================================================================
    // EVENTOS
    // =========================================================================
    event TicketPurchased(uint256 indexed ticketId, address indexed buyer, uint256 price);
    event TicketListedForResale(uint256 indexed ticketId, address indexed seller, uint256 resalePrice);
    event ResaleCancelled(uint256 indexed ticketId, address indexed seller);
    event ResaleTicketSold(uint256 indexed ticketId, address indexed previousOwner, address indexed newOwner, uint256 price);
    event TicketValidated(uint256 indexed ticketId, address indexed attendee);
    event FundsWithdrawn(address indexed organizer, uint256 amount);

    // =========================================================================
    // MODIFICADORES
    // =========================================================================
    modifier onlyOrganizer() {
        if (msg.sender != organizer) revert OnlyOrganizerAllowed();
        _;
    }

    modifier onlyTicketOwner(uint256 _ticketId) {
        if (_ticketId == 0 || _ticketId > ticketsSold) revert TicketDoesNotExist(_ticketId);
        if (tickets[_ticketId].owner != msg.sender) revert OnlyTicketOwnerAllowed();
        _;
    }

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================
    /**
     * @notice Inicializa el evento deportivo, concierto o espectáculo.
     * @param _totalTickets Aforo máximo de entradas.
     * @param _ticketPrice Precio oficial de salida (en Wei).
     * @param _maxMarkupPercentage Porcentaje extra de reventa permitido (ej. 10 para 10%, 0 para precio fijo).
     */
    constructor(
        uint256 _totalTickets,
        uint256 _ticketPrice,
        uint256 _maxMarkupPercentage
    ) {
        if (_totalTickets == 0) revert InvalidPrice();
        if (_ticketPrice == 0) revert InvalidPrice();

        organizer = msg.sender;
        totalTickets = _totalTickets;
        ticketPrice = _ticketPrice;
        maxMarkupPercentage = _maxMarkupPercentage;
        maxResalePrice = _ticketPrice + ((_ticketPrice * _maxMarkupPercentage) / 100);
    }

    // =========================================================================
    // VENTA INICIAL (COMPRA PRIMARIA)
    // =========================================================================
    /**
     * @notice Compra una entrada al precio inicial oficial.
     * @return ticketId Identificador único de la entrada asignada.
     */
    function buyTicket() external payable returns (uint256 ticketId) {
        if (ticketsSold >= totalTickets) revert SoldOut();
        if (msg.value != ticketPrice) revert IncorrectPayment(ticketPrice, msg.value);

        unchecked {
            ticketId = ++ticketsSold;
        }

        tickets[ticketId] = Ticket({
            owner: msg.sender,
            isUsed: false,
            isForSale: false,
            resalePrice: 0
        });

        emit TicketPurchased(ticketId, msg.sender, ticketPrice);
    }

    // =========================================================================
    // MERCADO SECUNDARIO / REVENTA CONTROLADA
    // =========================================================================
    /**
     * @notice Pone una entrada a la venta respetando el límite máximo fijado por el organizador.
     * @param _ticketId Número identificador de la entrada.
     * @param _price Precio pedido por el dueño (debe ser <= maxResalePrice).
     */
    function listTicketForResale(uint256 _ticketId, uint256 _price) external onlyTicketOwner(_ticketId) {
        Ticket storage ticket = tickets[_ticketId];

        if (ticket.isUsed) revert TicketAlreadyUsed(_ticketId);
        if (_price == 0) revert InvalidPrice();
        if (_price > maxResalePrice) revert PriceExceedsMaxLimit(_price, maxResalePrice);

        ticket.isForSale = true;
        ticket.resalePrice = _price;

        emit TicketListedForResale(_ticketId, msg.sender, _price);
    }

    /**
     * @notice Permite al dueño cancelar la reventa si decide asistir o no venderla.
     * @param _ticketId Número identificador de la entrada.
     */
    function cancelResale(uint256 _ticketId) external onlyTicketOwner(_ticketId) {
        Ticket storage ticket = tickets[_ticketId];
        if (!ticket.isForSale) revert TicketNotForSale(_ticketId);

        ticket.isForSale = false;
        ticket.resalePrice = 0;

        emit ResaleCancelled(_ticketId, msg.sender);
    }

    /**
     * @notice Compra una entrada puesta en reventa por otro usuario.
     * @dev El dinero se envía directamente al vendedor y la entrada cambia de dueño de forma atómica.
     * @param _ticketId Identificador de la entrada en reventa.
     */
    function buyResaleTicket(uint256 _ticketId) external payable {
        if (_ticketId == 0 || _ticketId > ticketsSold) revert TicketDoesNotExist(_ticketId);

        Ticket storage ticket = tickets[_ticketId];

        if (!ticket.isForSale) revert TicketNotForSale(_ticketId);
        if (ticket.isUsed) revert TicketAlreadyUsed(_ticketId);
        if (msg.sender == ticket.owner) revert CannotBuyOwnTicket();
        if (msg.value != ticket.resalePrice) revert IncorrectPayment(ticket.resalePrice, msg.value);

        address previousOwner = ticket.owner;
        uint256 salePrice = ticket.resalePrice;

        // Efectos de estado antes de transferir fondos (Patrón CEI: Checks-Effects-Interactions)
        ticket.owner = msg.sender;
        ticket.isForSale = false;
        ticket.resalePrice = 0;

        // Transferencia directa de fondos al vendedor original
        (bool sent, ) = payable(previousOwner).call{value: salePrice}("");
        if (!sent) revert TransferFailed();

        emit ResaleTicketSold(_ticketId, previousOwner, msg.sender, salePrice);
    }

    // =========================================================================
    // CONTROL DE ACCESO EN PUERTA
    // =========================================================================
    /**
     * @notice Valida una entrada en el acceso al evento e invalida su uso futuro.
     * @param _ticketId Identificador de la entrada.
     */
    function validateAccess(uint256 _ticketId) external onlyOrganizer {
        if (_ticketId == 0 || _ticketId > ticketsSold) revert TicketDoesNotExist(_ticketId);

        Ticket storage ticket = tickets[_ticketId];
        if (ticket.isUsed) revert TicketAlreadyUsed(_ticketId);

        ticket.isUsed = true;
        // Si estaba listada para reventa, se anula inmediatamente
        if (ticket.isForSale) {
            ticket.isForSale = false;
            ticket.resalePrice = 0;
        }

        emit TicketValidated(_ticketId, ticket.owner);
    }

    // =========================================================================
    // RETIRADA DE FONDOS DEL ORGANIZADOR
    // =========================================================================
    /**
     * @notice El organizador retira los fondos acumulados por la venta inicial de entradas.
     */
    function withdraw() external onlyOrganizer {
        uint256 contractBalance = address(this).balance;
        if (contractBalance == 0) revert NoFundsToWithdraw();

        (bool success, ) = payable(organizer).call{value: contractBalance}("");
        if (!success) revert TransferFailed();

        emit FundsWithdrawn(organizer, contractBalance);
    }

    // =========================================================================
    // CONSULTAS / VISTAS AUXILIARES
    // =========================================================================
    /**
     * @notice Devuelve la información completa de una entrada.
     */
    function getTicket(uint256 _ticketId) external view returns (
        address owner,
        bool isUsed,
        bool isForSale,
        uint256 resalePrice
    ) {
        if (_ticketId == 0 || _ticketId > ticketsSold) revert TicketDoesNotExist(_ticketId);
        Ticket storage t = tickets[_ticketId];
        return (t.owner, t.isUsed, t.isForSale, t.resalePrice);
    }

    /**
     * @notice Devuelve el número de entradas disponibles en venta inicial.
     */
    function getAvailableInitialTickets() external view returns (uint256) {
        return totalTickets - ticketsSold;
    }
}
